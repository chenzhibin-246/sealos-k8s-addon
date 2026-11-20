#!/usr/bin/env bash
# Explicit Sealos/Kubernetes check, install, add-on and guarded reset modes.
# Scope: Sealos v5.1.1, kubeadm baseline, and selected Kubernetes add-ons.
set -uo pipefail
set +x
umask 077

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0
FAIL_CODES_TEXT=""
OS_ID=""
OS_VERSION=""
OS_FAMILY=""
MASTER_IP=""
SSH_USER="root"
SSH_PORT=22
SSH_AUTH=key
SEALOS_VERSION=5.1.1
CNI=cilium
CHECK_INGRESS=0
CHECK_NFS=0
NO_COLOR="${NO_COLOR:-}"
CHECK_HOST_LIB_ONLY="${CHECK_HOST_LIB_ONLY:-0}"

usage() {
  cat <<'HELP'
用法: check-single-node-host.sh [check] [主机检测参数]
       check-single-node-host.sh install-k8s --bundle-dir DIR --master-ip IPV4
       check-single-node-host.sh install-addons --bundle-dir DIR
       check-single-node-host.sh reset-k8s --bundle-dir DIR --master-ip IPV4 \
         --expect-cluster-uid UID [--allow-storage-loss] [--dry-run]

功能 1 check（默认，只读）：
  --master-ip IPV4  --sealos-version VERSION  --ssh-user USER
  --ssh-port PORT    --ssh-auth key|password   --cni cilium|other
  --ingress-hostnetwork
  --check-nfs       只检查 NFS 客户端 mount.nfs

功能 2 install-k8s（仅新主机、仅离线）：
  --bundle-dir DIR  --master-ip IPV4  [--ssh-auth key|password]
  [--ssh-key /root/.ssh/id_rsa] [--ssh-user root] [--ssh-port 22]

功能 3 install-addons（仅本脚本新建的单节点集群、仅离线）：
  --bundle-dir DIR  [--kubeconfig /etc/kubernetes/admin.conf]
  [--context CONTEXT] [--metrics-insecure-tls]
  按 Cilium → ingress-nginx → metrics-server → csi-driver-nfs 安装。
  --metrics-insecure-tls 仅供 kubelet 自签证书的测试集群使用。

功能 4 reset-k8s（会删除整个 default 集群）：
  --bundle-dir DIR  --master-ip IPV4  --expect-cluster-uid UID
  [--ssh-auth key|password] [--ssh-key /root/.ssh/id_rsa]
  [--ssh-user root] [--ssh-port 22]
  检测到 PV/PVC 时，还必须传 --allow-storage-loss。
  --dry-run 只核对清理与重装前提，不执行 reset。
  reset 成功后仍要检查服务、端口及目录；残留未清则停止重装。

离线目录须包含指定版本的 Sealos/Helm、Kubernetes 集群镜像、
四个 Helm Chart 和全部组件镜像 tar。镜像统一位于 images/。
安装入口从不联网下载。
目标系统缺少 DEB/RPM 依赖时，从同系统离线依赖包本地安装；
本包可选带 host-packages/，不要使用目标主机的软件源补包。
reset-k8s 会删除现有 Kubernetes 对象、etcd 数据和集群配置；
外部存储数据也可能受 PV 回收策略影响。请先核对备份。
安装前先运行 check，并阅读所有 WARN 与 FAIL。
默认使用私钥；没有私钥时传 --ssh-auth password，并在终端输入 root 密码。
密码不作为脚本参数输入；Sealos 的 --passwd 可能在进程参数和
Clusterfile 中短暂或持续出现，请限制主机本地读取权限。
终端中 PASS/WARN/FAIL/INFO 使用不同颜色；重定向时为纯文本。
命令行前的 $ 是提示符，复制命令时不用输入。
退出码：0=成功；1=条件未满足或执行失败；2=参数错误。
HELP
}

color_enabled() {
  [[ -t 1 && -z "$NO_COLOR" && "${TERM:-dumb}" != dumb ]]
}

fix_step() { printf '    %s. %s\n' "$1" "$2"; }
fix_cmd() { printf '       $ %s\n' "$1"; }
fix_note() { printf '       %s\n' "$1"; }

package_for() {
  local name="$1"
  if [[ "$OS_FAMILY" == rhel ]]; then
    case "$name" in
      ip|ss) printf iproute ;;
      modprobe) printf kmod ;;
      findmnt|lsblk|swapon) printf util-linux ;;
      getconf) printf glibc-common ;;
      conntrack) printf conntrack-tools ;;
      mount.nfs) printf nfs-utils ;;
      *) printf '%s' "$name" ;;
    esac
  else
    case "$name" in
      ip|ss) printf iproute2 ;;
      modprobe) printf kmod ;;
      findmnt|lsblk|swapon) printf util-linux ;;
      getconf) printf libc-bin ;;
      conntrack) printf conntrack ;;
      mount.nfs) printf nfs-common ;;
      *) printf '%s' "$name" ;;
    esac
  fi
}

offline_package_commands() {
  fix_cmd 'cd /opt/sealos-k8s-offline'
  fix_cmd './install-host-packages-offline.sh --check /mnt/sealos-host-packages'
  fix_cmd 'sudo ./install-host-packages-offline.sh --install /mnt/sealos-host-packages'
  fix_note '若依赖包已嵌入主包，目录改为 ./host-packages。'
}

chart_uses_always_pull() {
  awk '
    $1 == "imagePullPolicy:" {
      gsub(/["\047]/, "", $2)
      if ($2 == "Always") found=1
    }
    END { exit found ? 0 : 1 }
  ' "$@"
}

print_fix() {
  local code="$1" arg="${2:-}" pkg
  printf '  解决步骤：\n'
  case "$code" in
    LINUX)
      fix_step 1 '登录实际要安装 Kubernetes 的 Linux 主机。'
      fix_cmd 'uname -s'
      fix_step 2 '确认输出为 Linux，再运行本预检。'
      ;;
    ROOT)
      fix_step 1 '用 id -u 核对当前用户。'
      fix_cmd 'id -u'
      fix_step 2 '用 sudo 和原参数重新运行预检。'
      fix_note '非 root 时磁盘、进程和 SSH 检查可能不完整。'
      ;;
    ARCH)
      fix_step 1 '确认 CPU 架构。'
      fix_cmd 'uname -m'
      fix_step 2 '选用 amd64 或 arm64 的 Sealos 与集群镜像。'
      fix_note '所选镜像的架构必须与所有目标节点一致。'
      ;;
    OS)
      fix_step 1 '确认发行版及版本。'
      fix_cmd 'cat /etc/os-release'
      fix_step 2 '核对 Sealos 和所选 CNI 对此系统的支持。'
      fix_note '建议使用受支持的完整 Linux 系统镜像。'
      ;;
    CPU)
      fix_step 1 '查看控制平面节点可用 CPU。'
      fix_cmd 'nproc'
      fix_step 2 '不足 2 CPU 时，在云平台或虚拟化平台扩容。'
      fix_step 3 '扩容后重新运行预检。'
      ;;
    MEMORY)
      fix_step 1 '查看物理内存。'
      fix_cmd 'grep MemTotal /proc/meminfo'
      if [[ "$arg" == low_margin ]]; then
        fix_step 2 '估算控制面、CNI、系统 Pod 和工作负载用量。'
        fix_step 3 '若余量不足，在云平台扩容后复查。'
      else
        fix_step 2 '不足 2 GiB 时先在云平台扩容。'
      fi
      ;;
    GLIBC)
      fix_step 1 '查看当前 libc。'
      fix_cmd 'getconf GNU_LIBC_VERSION'
      fix_step 2 '改用自带兼容 glibc 的发行版镜像。'
      fix_note '不要在现有系统中单独替换 libc。'
      ;;
    SYSTEMD)
      fix_step 1 '确认 PID 1 与服务管理器。'
      fix_cmd 'ps -p 1 -o comm='
      fix_cmd 'systemctl is-system-running'
      fix_step 2 '使用可正常运行 systemd 的主机镜像。'
      fix_note '仅安装 systemctl 命令不能代替 systemd。'
      ;;
    CGROUP)
      fix_step 1 '检查 cgroup 文件系统。'
      fix_cmd 'findmnt /sys/fs/cgroup'
      fix_step 2 '修正系统启动或内核的 cgroup 配置。'
      fix_step 3 '重启后重新检查挂载。'
      ;;
    KERNEL)
      fix_step 1 '确认当前运行内核。'
      fix_cmd 'uname -r'
      fix_step 2 '若使用 Cilium 1.19.4，改用 5.10+ 内核'
      fix_note '或经验证的等效供应商回移内核。'
      fix_step 3 '在维护窗口重启，再核对内核功能。'
      ;;
    KCONFIG)
      fix_step 1 '核对以下缺失的内核 CONFIG 项：'
      for item in $arg; do
        fix_note "$item"
      done
      fix_cmd 'ls -l /boot/config-$(uname -r) /proc/config.gz'
      fix_step 2 'CONFIG=m 且模块缺失时补齐同版模块包。'
      fix_note 'CONFIG=n 或缺项时换用支持该功能的内核。'
      fix_step 3 '重启后重新运行预检。'
      ;;
    KCONFIG_UNKNOWN)
      fix_step 1 '向镜像提供方取得运行内核的 config。'
      fix_cmd 'ls -l /boot/config-$(uname -r) /proc/config.gz'
      fix_step 2 '核对后重新运行预检。'
      ;;
    MODULE)
      fix_step 1 "核对 $arg 是否为内建或可加载模块。"
      fix_cmd "modprobe -n $arg"
      fix_step 2 '若缺模块，安装匹配 uname -r 的模块包。'
      fix_note '内核未编译该功能时需更换内核。'
      ;;
    SWAP)
      fix_step 1 '查看当前 swap。'
      fix_cmd 'swapon --show'
      fix_step 2 '默认 kubelet 不接受 swap；可临时关闭。'
      fix_cmd 'sudo swapoff -a'
      fix_step 3 '备份并核对 fstab 等持久配置。'
      fix_note '若要保留 swap，须按目标 kubelet 配置显式允许。'
      ;;
    FORWARD)
      fix_step 1 '查看 IPv4 转发。'
      fix_cmd 'sysctl net.ipv4.ip_forward'
      fix_step 2 '核对网络策略后启用。'
      fix_cmd 'sudo sysctl -w net.ipv4.ip_forward=1'
      fix_step 3 '写入持久 sysctl 配置并在重启后复查。'
      ;;
    CMD)
      pkg="$(package_for "$arg")"
      fix_step 1 "确认 $arg 是否在当前系统可用。"
      fix_cmd "command -v $arg"
      fix_step 2 "在同版、同架构准备机收集 $pkg 及传递依赖。"
      fix_note '按部署手册第 3 节制作并校验系统依赖包。'
      fix_step 3 '在目标机仅从本地包校验、安装。'
      offline_package_commands
      fix_step 4 "复查 command -v ${arg}。"
      ;;
    SSH_SERVICE)
      fix_step 1 "核对 SSH 服务及端口 ${SSH_PORT}。"
      fix_cmd 'sudo systemctl status sshd ssh --no-pager'
      fix_cmd 'sudo ss -lntp'
      fix_step 2 '缺包时准备 openssh-server 及传递依赖。'
      fix_note '使用同发行版、版本和架构的离线系统包。'
      offline_package_commands
      fix_step 3 '本地安装完成后启动服务。'
      if [[ "$OS_FAMILY" == rhel ]]; then
        fix_cmd 'sudo systemctl enable --now sshd'
      else
        fix_cmd 'sudo systemctl enable --now ssh'
      fi
      fix_step 4 '从运行 Sealos 的主机实测节点 SSH。'
      ;;
    SSH_AUTH)
      fix_step 1 "确认认证方式：--ssh-auth ${SSH_AUTH}。"
      fix_note 'Sealos 5.1.1 支持私钥 --pk 和密码 --passwd。'
      fix_step 2 '核对 sshd 的实际配置与 Match 规则。'
      fix_cmd 'sudo sshd -T | grep -E "^(permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) "'
      if [[ "$SSH_AUTH" == password ]]; then
        fix_note 'root 密码方式需要 PermitRootLogin yes，'
        fix_note '且 PasswordAuthentication yes。'
        fix_note 'Sealos 5.1.1 仅使用 SSH password 认证。'
        fix_step 3 '核对 root 账号是否有可用密码。'
        fix_cmd 'sudo passwd -S root'
        fix_note '显示 L、LK 或 NP 时，按管理策略设置 root 密码。'
        fix_cmd 'sudo passwd root'
        fix_step 4 '按主机 SSH 策略修改生效的 sshd 配置。'
        fix_note '例如设置 PermitRootLogin yes、PasswordAuthentication yes；'
        fix_note '核对 Include 文件和 Match 规则，先保留现有管理会话。'
        fix_cmd 'sudo sshd -t'
        fix_cmd 'sudo systemctl reload sshd || sudo systemctl reload ssh'
        fix_step 5 '从 Sealos 发起端用 root 密码实测登录。'
      else
        fix_step 3 '从 Sealos 发起端用指定私钥实测登录。'
        fix_note '只确认公钥存在不能证明私钥和网络可用。'
      fi
      ;;
    MASTER_IP)
      fix_step 1 '列出本机 IPv4 地址。'
      fix_cmd 'ip -4 addr show'
      fix_step 2 '把实际私网地址传给 --master-ip。'
      fix_note '公有云优先使用内网 IP。'
      ;;
    TIME)
      fix_step 1 '检查系统时间与同步状态。'
      fix_cmd 'timedatectl status'
      fix_step 2 '先配置可达的内网 NTP 时间源。'
      fix_note '不得依赖默认公网 NTP；无内网源时按现场规程校时。'
      fix_step 3 '从其他节点核对时间偏差后重新预检。'
      ;;
    HOSTNAME)
      fix_step 1 '查看当前主机名。'
      fix_cmd 'hostname'
      fix_step 2 '设置无下划线且在集群内唯一的名称。'
      fix_note '修改前先确认现有业务对主机名的依赖。'
      ;;
    EXISTING_CLUSTER)
      fix_step 1 '确认现有集群的节点和业务归属。'
      fix_cmd 'kubectl get nodes -o wide'
      fix_cmd 'sudo systemctl status kubelet --no-pager'
      fix_note '发现的配置文件：'
      fix_note '/etc/kubernetes/manifests/kube-apiserver.yaml'
      fix_note '/etc/kubernetes/kubelet.conf'
      fix_step 2 '若要保留集群，按加入/升级方案处理。'
      fix_note '全新创建应使用空白主机或经批准的迁移计划。'
      fix_step 3 '不要在运行中的节点直接 reset 或删目录。'
      ;;
    CONTAINERD)
      fix_step 1 '核对现有运行时与集群状态。'
      fix_cmd 'containerd --version'
      fix_cmd 'kubectl get nodes -o wide'
      if [[ "$arg" == version_failed ]]; then
        fix_step 2 '确认命令路径及运行错误。'
        fix_cmd 'command -v containerd'
        fix_note '此状态需查明来源，不能据此判定已可安装。'
      elif [[ "$SEALOS_VERSION" == 5.1.1 ]]; then
        fix_step 2 'Sealos 5.1.1 新建集群会拒绝'
        fix_note '已安装的 containerd。'
      else
        fix_step 2 '按目标 Sealos 版本核对其运行时检查。'
      fi
      fix_step 3 '若属于运行中集群，保留现有服务。'
      fix_note '全新创建请改用空白主机或走迁移审批。'
      ;;
    PORT|INGRESS_PORT)
      fix_step 1 '确认监听进程及端口归属。'
      fix_cmd 'sudo ss -lntp'
      fix_step 2 '若属于现有 Kubernetes，先确认集群用途。'
      fix_note '不要仅因占用端口就停用控制面。'
      fix_step 3 '若为其他服务，调整安装方案或迁移服务。'
      fix_note '云安全组需从实际客户端另行验证。'
      ;;
    DISK_SPACE)
      fix_step 1 '查看根分区与运行时目录可用空间。'
      fix_cmd 'df -hT / /var/lib/containerd'
      fix_step 2 '按目标集群镜像和后续工作负载规划磁盘。'
      fix_note '没有统一的 Sealos 100 GB 硬门槛。'
      ;;
    NFS_CLIENT)
      fix_step 1 '确认节点是否计划作为 NFS 客户端。'
      fix_cmd 'command -v mount.nfs'
      fix_step 2 '缺少客户端工具时准备对应离线包。'
      if [[ "$OS_FAMILY" == rhel ]]; then
        fix_note 'RHEL/Rocky：nfs-utils 与全部传递依赖。'
      else
        fix_note 'Ubuntu/Debian：nfs-common 与全部传递依赖。'
      fi
      fix_step 3 '在目标机仅从本地包校验、安装。'
      offline_package_commands
      fix_step 4 '从该节点试挂载计划的 NFS 导出。'
      fix_note '核对服务端地址、导出路径和客户端授权。'
      ;;
    FIREWALL)
      fix_step 1 '读取当前防火墙策略。'
      fix_cmd 'sudo firewall-cmd --list-all'
      fix_step 2 '按控制面和所选 CNI 端口开通内网访问。'
      fix_note '不要不经核对就关闭防火墙或开放公网。'
      ;;
    SEALOS_VERSION)
      fix_step 1 '核对计划使用的 Sealos 版本。'
      fix_cmd 'sealos version'
      fix_step 2 '不同版本的前置检查可能不同。'
      fix_note '按对应版本文档和源码重新核实。'
      ;;
    *)
      fix_step 1 '按上方异常信息核对目标主机。'
      fix_step 2 '修复后重新运行本预检。'
      ;;
  esac
}

report() {
  local level="$1" message="$2" code="${3:-}" color="" code_label=""
  if [[ -n "$code" ]]; then code_label="[$code]"; fi
  if color_enabled; then
    case "$level" in
      PASS) color=32 ;; WARN) color=33 ;;
      FAIL) color=31 ;; INFO) color=36 ;;
    esac
  fi
  if [[ -n "$color" ]]; then
    printf '\033[%sm[%-4s]\033[0m%s %s\n' "$color" "$level" "$code_label" "$message"
  else
    printf '[%-4s]%s %s\n' "$level" "$code_label" "$message"
  fi
  case "$level" in
    PASS) PASS_COUNT=$((PASS_COUNT+1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT+1)) ;;
    FAIL)
      FAIL_COUNT=$((FAIL_COUNT+1))
      FAIL_CODES_TEXT+="  $FAIL_COUNT. [${code:-CHECK}]"$'\n'
      ;;
    INFO) INFO_COUNT=$((INFO_COUNT+1)) ;;
  esac
  if [[ "$level" == WARN || "$level" == FAIL ]]; then
    print_fix "${code:-CHECK}" "${4:-}"
    printf '\n'
  fi
}

print_summary() {
  local total
  total=$((PASS_COUNT+WARN_COUNT+FAIL_COUNT+INFO_COUNT))
  printf '\n========== Sealos/K8s 预检汇总 ==========\n'
  printf '检查项总数: %s\n' "$total"
  if color_enabled; then
    printf '汇总: \033[32mPASS=%s\033[0m  \033[33mWARN=%s\033[0m  \033[31mFAIL=%s\033[0m  \033[36mINFO=%s\033[0m\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$INFO_COUNT"
  else
    printf '汇总: PASS=%s  WARN=%s  FAIL=%s  INFO=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$INFO_COUNT"
  fi
  if ((FAIL_COUNT>0)); then
    printf '未通过项：\n%s' "$FAIL_CODES_TEXT"
    if color_enabled; then
      printf '\033[31m结论：不满足当前 Sealos/K8s 全新安装条件。\033[0m\n'
    else
      printf '结论：不满足当前 Sealos/K8s 全新安装条件。\n'
    fi
    printf '处理：核对上方 FAIL，再重新运行预检。\n'
  elif ((WARN_COUNT>0)); then
    if color_enabled; then
      printf '\033[33m结论：无硬性阻断，仍有待核对项。\033[0m\n'
    else
      printf '结论：无硬性阻断，仍有待核对项。\n'
    fi
    printf '处理：逐项确认 WARN 后再决定安装。\n'
  else
    if color_enabled; then
      printf '\033[32m结论：已检查的主机条件通过。\033[0m\n'
    else
      printf '结论：已检查的主机条件通过。\n'
    fi
    printf '说明：仍需验证节点互通和实际安装结果。\n'
  fi
}

version_at_least() {
  local actual="$1" floor_major="$2" floor_minor="$3" major minor
  [[ "$actual" =~ ^([0-9]+)(\.([0-9]+))? ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[3]:-0}"
  ((major>floor_major || (major==floor_major && minor>=floor_minor)))
}

os_policy() {
  local os_id="$1" version="$2"
  case "$os_id" in
    ubuntu) version_at_least "$version" 20 4 ;;
    debian) version_at_least "$version" 10 0 ;;
    rhel|centos|rocky|almalinux|ol)
      version_at_least "$version" 8 6 ;;
    *) return 1 ;;
  esac
}

cilium_kernel_policy() {
  local release="$1" os_id="$2" os_version="$3" major minor
  [[ "$release" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  if ((major>5 || (major==5 && minor>=10))); then return 0; fi
  [[ "$os_id" == rhel && "$os_version" == 8.10 &&
     "$major" == 4 && "$minor" == 18 ]]
}

port_listening() {
  local listeners="$1" port="$2" state recv send local_addr rest
  while read -r state recv send local_addr rest; do
    [[ "$local_addr" == *":$port" ]] && return 0
  done <<<"$listeners"
  return 1
}

# Installation modes use only local artifacts. They are never entered by the
# default read-only check command.
K8S_IMAGE_REF='swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/labring/kubernetes:v1.33.6'
STATE_DIR="${SEALOS_K8S_STATE_DIR:-/var/lib/sealos-k8s-setup}"
BUNDLE_DIR=''
SSH_KEY='/root/.ssh/id_rsa'
SSH_KEY_EXPLICIT=0
SSH_PASSWORD=''
KUBECONFIG_PATH='/etc/kubernetes/admin.conf'
KUBE_CONTEXT=''
EXPECT_CLUSTER_UID=''
ALLOW_STORAGE_LOSS=0
RESET_DRY_RUN=0
METRICS_INSECURE_TLS=0

op_line() {
  local level="$1" message="$2" color=''
  if color_enabled; then
    case "$level" in
      PASS) color=32 ;; WARN) color=33 ;; FAIL) color=31 ;; INFO) color=36 ;;
    esac
  fi
  if [[ -n "$color" ]]; then
    printf '\033[%sm[%-4s]\033[0m %s\n' "$color" "$level" "$message"
  else
    printf '[%-4s] %s\n' "$level" "$message"
  fi
}

op_fail() {
  local message="$1" step=1
  shift
  op_line FAIL "$message" >&2
  if (($#)); then
    printf '  解决步骤：\n' >&2
    while (($#)); do
      printf '    %s. %s\n' "$step" "$1" >&2
      step=$((step+1))
      shift
    done
  fi
  exit 1
}

parse_install_args() {
  local mode="$1"
  shift
  while (($#)); do
    case "$1" in
      --bundle-dir|--master-ip|--ssh-key|--ssh-user|--ssh-port|--ssh-auth|--kubeconfig|--context|--expect-cluster-uid)
        case "$mode:$1" in
          install-k8s:--bundle-dir|install-k8s:--master-ip|\
          install-k8s:--ssh-key|install-k8s:--ssh-user|install-k8s:--ssh-auth|\
          install-k8s:--ssh-port|install-addons:--bundle-dir|\
          install-addons:--kubeconfig|install-addons:--context|\
          reset-k8s:--bundle-dir|reset-k8s:--master-ip|\
          reset-k8s:--ssh-key|reset-k8s:--ssh-user|reset-k8s:--ssh-auth|\
          reset-k8s:--ssh-port|reset-k8s:--expect-cluster-uid) ;;
          *) printf '%s 不接受参数 %s。\n' "$mode" "$1" >&2; exit 2 ;;
        esac
        if (($#<2)) || [[ -z "$2" ]]; then
          printf '参数 %s 缺少值。\n' "$1" >&2
          exit 2
        fi
        case "$1" in
          --bundle-dir) BUNDLE_DIR="$2" ;;
          --master-ip) MASTER_IP="$2" ;;
          --ssh-key) SSH_KEY="$2"; SSH_KEY_EXPLICIT=1 ;;
          --ssh-user) SSH_USER="$2" ;;
          --ssh-port) SSH_PORT="$2" ;;
          --ssh-auth) SSH_AUTH="$2" ;;
          --kubeconfig) KUBECONFIG_PATH="$2" ;;
          --context) KUBE_CONTEXT="$2" ;;
          --expect-cluster-uid) EXPECT_CLUSTER_UID="$2" ;;
        esac
        shift 2 ;;
      --allow-storage-loss)
        [[ "$mode" == reset-k8s ]] || {
          printf '%s 不接受参数 %s。\n' "$mode" "$1" >&2
          exit 2
        }
        ALLOW_STORAGE_LOSS=1
        shift ;;
      --dry-run)
        [[ "$mode" == reset-k8s ]] || {
          printf '%s 不接受参数 %s。\n' "$mode" "$1" >&2
          exit 2
        }
        RESET_DRY_RUN=1
        shift ;;
      --metrics-insecure-tls)
        [[ "$mode" == install-addons ]] || {
          printf '%s 不接受参数 %s。\n' "$mode" "$1" >&2
          exit 2
        }
        METRICS_INSECURE_TLS=1
        shift ;;
      --help|-h) usage; exit 0 ;;
      *) printf '未知的 %s 参数: %s\n' "$mode" "$1" >&2; exit 2 ;;
    esac
  done
  if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT<1 || SSH_PORT>65535)); then
    printf 'SSH 端口应为 1–65535。\n' >&2
    exit 2
  fi
  if [[ ! "$SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    printf 'SSH 用户名格式不正确。\n' >&2
    exit 2
  fi
  if [[ "$SSH_AUTH" != key && "$SSH_AUTH" != password ]]; then
    printf '%s\n' '--ssh-auth 只能是 key 或 password。' >&2
    exit 2
  fi
  if [[ "$SSH_AUTH" == password ]]; then
    if [[ "$SSH_USER" != root ]]; then
      printf '%s\n' '密码方式仅支持 --ssh-user root。' >&2
      exit 2
    fi
    if ((SSH_KEY_EXPLICIT)); then
      printf '%s\n' '--ssh-auth password 不能同时指定 --ssh-key。' >&2
      exit 2
    fi
  fi
  if [[ -z "$BUNDLE_DIR" ]]; then
    printf '%s 必须指定 --bundle-dir。\n' "$mode" >&2
    exit 2
  fi
  if [[ "$mode" == reset-k8s &&
        ( -z "$MASTER_IP" || -z "$EXPECT_CLUSTER_UID" ) ]]; then
    printf 'reset-k8s 必须同时指定 --master-ip 和 --expect-cluster-uid。\n' >&2
    exit 2
  fi
}

require_ssh_login() {
  command -v ssh >/dev/null 2>&1 || op_fail '缺少 ssh 客户端。' \
    '离线准备 openssh-client 或 openssh-clients 及依赖。'
  if [[ "$SSH_AUTH" == key ]]; then
    [[ -r "$SSH_KEY" ]] || op_fail "SSH 私钥不可读：$SSH_KEY" \
      '在主节点准备私钥，或改用 --ssh-auth password。'
    ssh -i "$SSH_KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes \
      -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=yes \
      "${SSH_USER}@${MASTER_IP}" true </dev/null >/dev/null 2>&1 ||
      op_fail '无法用指定私钥 SSH 登录本机私网 IP。' \
        "手动测试：ssh -i $SSH_KEY -p $SSH_PORT ${SSH_USER}@${MASTER_IP}" \
        '核对 authorized_keys 与 known_hosts 中已验证的主机指纹。'
    return 0
  fi
  if ! (: </dev/tty) 2>/dev/null; then
    op_fail '密码方式需要交互式终端。' \
      '在目标主机终端运行；不要通过无 TTY 的后台任务或管道传密码。'
  fi
  op_line INFO "请按 SSH 提示输入 root 密码，验证 ${MASTER_IP}:${SSH_PORT} 自连接。"
  ssh -p "$SSH_PORT" -o BatchMode=no -o NumberOfPasswordPrompts=1 \
    -o PreferredAuthentications=password \
    -o KbdInteractiveAuthentication=no -o PubkeyAuthentication=no \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=yes \
    "root@${MASTER_IP}" true </dev/tty >/dev/null 2>&1 ||
    op_fail 'root 密码 SSH 自连接失败。' \
      '核对 PermitRootLogin、PasswordAuthentication、密码及 known_hosts。' \
      "手动测试：ssh -p $SSH_PORT -o PreferredAuthentications=password -o KbdInteractiveAuthentication=no root@${MASTER_IP} true"
}

prompt_ssh_password() {
  if ! (: </dev/tty) 2>/dev/null; then
    op_fail 'Sealos 密码认证需要交互式终端。' \
      '登录目标主节点终端后重试；不要在命令行输入明文密码。'
  fi
  SSH_PASSWORD=''
  if ! IFS= read -r -s -p '请再次输入 root SSH 密码供 Sealos 使用：' \
      SSH_PASSWORD </dev/tty; then
    printf '\n' >/dev/tty
    op_fail '未能从终端读取 root SSH 密码。' '重新在交互式终端执行。'
  fi
  printf '\n' >/dev/tty
  [[ -n "$SSH_PASSWORD" ]] || op_fail 'root SSH 密码不能为空。' \
    '重新执行并输入实际密码。'
  op_line WARN 'Sealos 5.1.1 的 --passwd 可能暴露在本机进程参数和 Clusterfile 中。'
}

redact_password_stream() {
  local secret="$1" line=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//"$secret"/[REDACTED]}"
  done
}

scrub_clusterfile_ssh_password() {
  local file="$1" temp
  [[ -f "$file" ]] || return 0
  temp="$(mktemp "${file}.scrub.XXXXXX")" || return 1
  if ! awk '
    /^  ssh:[[:space:]]*$/ { in_ssh=1; print; next }
    in_ssh && (/^[^[:space:]]/ || /^  [^[:space:]#]/) { in_ssh=0 }
    in_ssh && /^    passwd:/ { print "    passwd: \"\""; next }
    { print }
  ' "$file" > "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  chmod 0600 "$temp" || { rm -f -- "$temp"; return 1; }
  mv -f -- "$temp" "$file"
}

scrub_recent_clusterfiles() {
  local since="$1" file
  [[ -d /root/.sealos/default ]] || return 0
  scrub_clusterfile_ssh_password /root/.sealos/default/Clusterfile || return 1
  while IFS= read -r -d '' file; do
    scrub_clusterfile_ssh_password "$file" || return 1
  done < <(find /root/.sealos/default -maxdepth 1 -type f \
    \( -name Clusterfile -o -name 'Clusterfile.[0-9]*' \) \
    -cnewer "$since" -print0)
}

require_bundle() {
  [[ -d "$BUNDLE_DIR" ]] || op_fail "离线目录不存在：$BUNDLE_DIR" \
    '将完整的 Kubernetes 离线包复制到目标主机。' \
    '使用 --bundle-dir 指向包含 bin、charts、images 的目录。'
  BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd -P)"
}

bundle_image_file() {
  local file="$BUNDLE_DIR/images/$1" legacy_file="$BUNDLE_DIR/$2"
  if [[ ! -e "$file" && ! -L "$file" && -e "$legacy_file" ]]; then
    # Older bundles and the workspace source tree use separate locations.
    file="$legacy_file"
  fi
  printf '%s\n' "$file"
}

require_file() {
  [[ -s "$1" ]] || op_fail "缺少离线文件：$1" \
    '在联网准备机取得该文件及对应架构的镜像。' \
    '传到离线目录后重新运行；脚本不会联网补下载。'
}

require_oci_ref() {
  local archive="$1" ref="$2" index
  require_file "$archive"
  index="$(tar -xOf "$archive" index.json 2>/dev/null)" ||
    op_fail "镜像归档不可读取：$archive" '确认它是可导入的 OCI 镜像 tar。'
  [[ "$index" == *"$ref"* ]] ||
    op_fail "镜像归档缺少预期引用：$ref" \
      "检查 $archive 的 index.json。" \
      '按 Chart 中的完整镜像引用重新准备离线镜像。'
}

require_oci_digest() {
  local archive="$1" digest="$2" index actual
  index="$(tar -xOf "$archive" index.json 2>/dev/null)" ||
    op_fail "无法读取镜像索引：$archive" '核对 OCI tar 完整性。'
  grep -Fq "$digest" <<<"$index" ||
    op_fail "镜像索引缺少 Chart 固定摘要：$digest" \
      "核对 $archive 与 Chart 渲染的镜像摘要。"
  actual="$(tar -xOf "$archive" "blobs/sha256/${digest#sha256:}" 2>/dev/null |
    sha256sum)" ||
    op_fail "无法校验镜像 manifest：$archive" '重新复制完整 OCI tar。'
  actual="${actual%% *}"
  [[ "sha256:$actual" == "$digest" ]] ||
    op_fail "镜像 manifest 摘要错误：$archive" '重新准备离线镜像。'
}

require_cluster_image_amd64() {
  local archive="$1" index manifest config manifest_hex config_hex
  index="$(tar -xOf "$archive" index.json 2>/dev/null)" ||
    op_fail 'Kubernetes 集群镜像 index.json 不可读。' '重新准备离线集群镜像。'
  manifest_hex="$(printf '%s' "$index" | grep -oE 'sha256:[0-9a-f]{64}' | head -n 1)"
  manifest_hex="${manifest_hex#sha256:}"
  [[ "$manifest_hex" =~ ^[0-9a-f]{64}$ ]] ||
    op_fail 'Kubernetes 集群镜像 manifest 摘要无效。' '核对 OCI 归档。'
  manifest="$(tar -xOf "$archive" "blobs/sha256/$manifest_hex" 2>/dev/null)" ||
    op_fail 'Kubernetes 集群镜像 manifest 不可读。' '核对 OCI 归档。'
  config_hex="$(printf '%s' "$manifest" | grep -oE 'sha256:[0-9a-f]{64}' | head -n 1)"
  config_hex="${config_hex#sha256:}"
  [[ "$config_hex" =~ ^[0-9a-f]{64}$ ]] ||
    op_fail 'Kubernetes 集群镜像 config 摘要无效。' '核对 OCI 归档。'
  config="$(tar -xOf "$archive" "blobs/sha256/$config_hex" 2>/dev/null)" ||
    op_fail 'Kubernetes 集群镜像 config 不可读。' '核对 OCI 归档。'
  grep -Eq '"architecture"[[:space:]]*:[[:space:]]*"amd64"' <<<"$config" ||
    op_fail 'Kubernetes 集群镜像不是 linux/amd64。' \
      '准备与主机 CPU 架构一致的 ClusterImage。'
  grep -Eq '"os"[[:space:]]*:[[:space:]]*"linux"' <<<"$config" ||
    op_fail 'Kubernetes 集群镜像不是 Linux 平台。' \
      '准备 linux/amd64 ClusterImage。'
}

chart_metadata() {
  local archive="$1" name="$2" version="$3" metadata
  require_file "$archive"
  metadata="$(tar -xOf "$archive" "$name/Chart.yaml" 2>/dev/null)" ||
    op_fail "Chart 归档损坏或名称不符：$archive" '重新准备官方 Helm Chart。'
  grep -Fxq "name: $name" <<<"$metadata" ||
    op_fail "Chart 名称不是 ${name}：$archive" '核对 Chart.yaml，不能用其他组件替代。'
  grep -Fxq "version: $version" <<<"$metadata" ||
    op_fail "Chart 版本不是 ${version}：$archive" '使用指定版本重新准备离线 Chart。'
}

sealos_cli_version() {
  "$1" version 2>/dev/null |
    sed -n '/^SealosVersion:/,$ {s/^[[:space:]]*gitVersion:[[:space:]]*//p;}' |
    head -n 1
}

finalize_new_cluster() {
  local expected_identity actual_identity cluster_uid attempt ready=0
  expected_identity="$(<"$STATE_DIR/install.pending")"
  actual_identity="$MASTER_IP $(cat /etc/machine-id 2>/dev/null)"
  [[ "$expected_identity" == "$actual_identity" ]] ||
    op_fail '待确认安装记录与本机身份或私网 IP 不匹配。' \
      '核对 --master-ip 与 /etc/machine-id；不要把状态文件复制到其他主机。'
  command -v kubectl >/dev/null 2>&1 ||
    op_fail 'sealos run 已返回成功，但 kubectl 不可用。' \
      '核对 /etc/kubernetes/admin.conf 与 Sealos 安装日志。'
  [[ -r /etc/kubernetes/admin.conf ]] ||
    op_fail 'sealos run 已返回成功，但 admin.conf 尚不可读。' \
      '检查控制面服务；修复后重跑同一条 install-k8s 命令以继续验证。'
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    if kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw=/readyz \
         >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 5
  done
  ((ready)) || op_fail '控制面 API /readyz 尚未就绪。' \
    '检查 kube-apiserver 与 etcd；不要立即 reset。' \
    '修复后重跑同一条 install-k8s 命令，只会继续验证。'
  cluster_uid="$(kubectl --kubeconfig /etc/kubernetes/admin.conf \
    get namespace kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)" ||
    op_fail '控制面 API 已就绪，但 kube-system UID 未读到。' \
      '检查 API 日志后重跑同一条 install-k8s 命令。'
  [[ -n "$cluster_uid" ]] || op_fail '未取得新集群 UID。' \
    '检查 API 日志后重跑同一条 install-k8s 命令。'
  (umask 077; printf '%s\n' "$cluster_uid" > "$STATE_DIR/cluster.uid") ||
    op_fail '无法写入新集群标记。' '核对状态目录权限。'
  rm -f "$STATE_DIR/install.pending"
  op_line PASS "Kubernetes 控制面可访问；集群 UID=${cluster_uid}。"
  op_line INFO '接下来运行 install-addons；CNI 安装前节点可能暂为 NotReady。'
}

install_k8s_main() {
  local sealos_archive image_tar candidate_dir sealos_bin old_path interface rules
  local run_failed=0
  parse_install_args install-k8s "$@"
  [[ "$(uname -s)" == Linux ]] ||
    op_fail 'install-k8s 必须在目标 Linux 首个主节点上执行。' \
      '登录目标 Linux 节点后运行。'
  [[ -n "$MASTER_IP" ]] || { printf 'install-k8s 必须指定 --master-ip。\n' >&2; exit 2; }
  if [[ -s "$STATE_DIR/install.pending" ]]; then
    [[ "$(id -u)" == 0 ]] || op_fail '继续验证新集群需要 root 权限。' \
      '使用 sudo 重跑同一条 install-k8s 命令。'
    op_line INFO '发现上次安装的待确认记录；只继续验证控制面。'
    finalize_new_cluster
    return 0
  fi

  # Reject a live/previous cluster before touching any bundled binary or image.
  if [[ -e /etc/kubernetes/kubelet.conf ||
        -e /etc/kubernetes/manifests/kube-apiserver.yaml ]] ||
     { command -v containerd >/dev/null 2>&1 &&
       containerd --version >/dev/null 2>&1; }; then
    op_fail '已发现 Kubernetes 或 containerd，禁止按全新集群覆盖安装。' \
      '先用 kubectl get nodes -o wide 核对现有集群。' \
      '保留现有集群；全新安装请使用空白主机。'
  fi
  if command -v kubectl >/dev/null 2>&1 &&
     kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then
    op_fail 'kubectl 可访问已有集群，停止全新安装。' \
      '确认当前 kubeconfig 指向的集群；在空白主机重试。'
  fi
  for old_path in /etc/kubernetes /etc/cni/net.d /var/lib/etcd \
                  /var/lib/kubelet /var/lib/containerd \
                  /var/lib/sealos/data/default /root/.sealos/default; do
    if [[ -d "$old_path" ]] &&
       [[ -n "$(find "$old_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      op_fail "发现旧安装数据：$old_path；禁止覆盖安装。" \
        "先核对 $old_path 的来源与用途。" \
        '使用空白主机部署全新集群；不要直接删除现有数据。'
    fi
  done
  for interface in cilium_host cilium_net kube-ipvs0; do
    if command -v ip >/dev/null 2>&1 &&
       ip link show "$interface" >/dev/null 2>&1; then
      op_fail "发现旧 Kubernetes/Cilium 网络接口：$interface。" \
        '核对集群是否已完整清理；不要在旧网络状态下重装。'
    fi
  done
  if command -v iptables-save >/dev/null 2>&1; then
    rules="$(iptables-save 2>/dev/null || true)"
    if grep -Eq '(^:|^-A )(KUBE-|CILIUM_)' <<<"$rules"; then
      op_fail '发现旧 Kubernetes/Cilium iptables 规则。' \
        '核对规则归属；停止相关服务后定向清理或重启复查。'
    fi
  fi
  if command -v nft >/dev/null 2>&1; then
    rules="$(nft list ruleset 2>/dev/null || true)"
    if grep -Eq 'KUBE-|CILIUM_' <<<"$rules"; then
      op_fail '发现旧 Kubernetes/Cilium nftables 规则。' \
        '核对规则归属；停止相关服务后定向清理或重启复查。'
    fi
  fi
  [[ "$(id -u)" == 0 ]] ||
    op_fail 'install-k8s 需要 root 权限。' \
      '使用 sudo 运行并先核对主机预检报告。'
  [[ "$(uname -m)" == x86_64 ]] ||
    op_fail '当前离线包仅含 linux/amd64 的 Sealos 与 Kubernetes 镜像。' \
      '在 amd64 主机运行，或另准备同架构的完整离线包。'

  require_bundle
  sealos_archive="$BUNDLE_DIR/bin/sealos_5.1.1_linux_amd64.tar.gz"
  image_tar="$(bundle_image_file kubernetes-v1.33.6.tar sealos-images/kubernetes-v1.33.6.tar)"
  require_file "$sealos_archive"
  tar -tzf "$sealos_archive" 2>/dev/null | grep -Fx sealos >/dev/null ||
    op_fail "Sealos 压缩包损坏：$sealos_archive" '重新准备 5.1.1 linux/amd64 压缩包。'
  require_oci_ref "$image_tar" "$K8S_IMAGE_REF"
  require_cluster_image_amd64 "$image_tar"
  require_ssh_login

  op_line INFO '执行全新安装前的只读主机检测。'
  bash "${BASH_SOURCE[0]}" check --master-ip "$MASTER_IP" \
    --sealos-version 5.1.1 --ssh-user "$SSH_USER" \
    --ssh-port "$SSH_PORT" --ssh-auth "$SSH_AUTH" --cni cilium \
    --ingress-hostnetwork --check-nfs ||
    op_fail '主机预检有 FAIL，未开始 Sealos 安装。' \
      '按上方“解决步骤”处理后重新运行。'

  mkdir -p "$STATE_DIR" || op_fail '无法创建安装状态目录。' '核对目录权限。'
  chmod 0700 "$STATE_DIR" || op_fail '无法保护安装状态目录。' '核对目录权限。'
  [[ -w "$STATE_DIR" ]] || op_fail '安装状态目录不可写。' '核对目录权限。'

  candidate_dir="$(mktemp -d /tmp/sealos-k8s-install.XXXXXX)" ||
    op_fail '无法创建临时目录。' '核对 /tmp 空间与权限。'
  trap "rm -rf -- $(printf '%q' "$candidate_dir")" EXIT
  tar -xzf "$sealos_archive" -C "$candidate_dir" sealos ||
    op_fail '解压 Sealos CLI 失败。' '核对离线压缩包完整性。'
  sealos_bin="$candidate_dir/sealos"
  [[ "$(sealos_cli_version "$sealos_bin")" == 5.1.1 ]] ||
    op_fail '离线包中的 Sealos CLI 版本不是 5.1.1。' '核对版本后重试。'
  if command -v sealos >/dev/null 2>&1; then
    [[ "$(sealos_cli_version "$(command -v sealos)")" == 5.1.1 ]] ||
      op_fail '主机已有其他版本 Sealos CLI，停止安装。' \
        '先核对现有 CLI 及其集群用途，避免覆盖。'
    sealos_bin="$(command -v sealos)"
  else
    install -m 0755 "$sealos_bin" /usr/local/bin/sealos ||
      op_fail '安装 Sealos CLI 失败。' '核对 /usr/local/bin 权限与空间。'
    sealos_bin=/usr/local/bin/sealos
  fi
  op_line PASS 'Sealos 5.1.1 CLI 已就绪。'
  "$sealos_bin" load -i "$image_tar" ||
    op_fail 'Sealos 导入 Kubernetes 集群镜像失败。' \
      '核对镜像 tar 完整性和磁盘可用空间。'
  "$sealos_bin" inspect "$K8S_IMAGE_REF" >/dev/null 2>&1 ||
    op_fail 'Sealos 本地存储中找不到预期的 Kubernetes 引用。' \
      '用 sealos inspect <完整镜像引用> 核对导入结果。'
  (umask 077; printf '%s %s\n' "$MASTER_IP" "$(cat /etc/machine-id)" \
    > "$STATE_DIR/install.pending") ||
    op_fail '无法记录待确认集群。' \
      '核对状态目录；未开始 sealos run。'
  op_line INFO "开始在本机私网 IP $MASTER_IP 创建单节点 Kubernetes。"
  if [[ "$SSH_AUTH" == password ]]; then
    prompt_ssh_password
    if ! "$sealos_bin" run "$K8S_IMAGE_REF" \
        --masters "$MASTER_IP" --user root --port "$SSH_PORT" \
        --passwd "$SSH_PASSWORD" 2>&1 |
        redact_password_stream "$SSH_PASSWORD"; then
      run_failed=1
    fi
    unset SSH_PASSWORD
    scrub_clusterfile_ssh_password /root/.sealos/default/Clusterfile ||
      op_fail '无法清除 Sealos Clusterfile 中的 SSH 密码。' \
        '立即以 root 限制文件权限并检查 spec.ssh.passwd。'
    ((run_failed == 0)) || op_fail 'sealos run 失败。' \
      '查看 Sealos 输出和 /var/log 中对应日志。' \
      '不要在未确认状态前直接 reset 或重新 run。'
  else
    "$sealos_bin" run "$K8S_IMAGE_REF" \
      --masters "$MASTER_IP" --user "$SSH_USER" \
      --port "$SSH_PORT" --pk "$SSH_KEY" ||
      op_fail 'sealos run 失败。' \
        '查看 Sealos 输出和 /var/log 中对应日志。' \
        '不要在未确认状态前直接 reset 或重新 run。'
  fi
  finalize_new_cluster
}

install_addons_main() {
  local helm_archive cilium_chart ingress_chart metrics_chart nfs_chart
  local cilium_values ingress_values image_index output uid marker
  local image_manifest expected_sha actual_sha
  local imported_refs ref
  local workdir helm_bin addon_tar metrics_ready attempt node image
  local expected_images rendered_images
  local -a metrics_tls_args=()
  parse_install_args install-addons "$@"
  if [[ "$METRICS_INSECURE_TLS" == 1 ]]; then
    metrics_tls_args=(--set-string 'args[0]=--kubelet-insecure-tls')
    op_line WARN 'Metrics Server 将跳过 kubelet 服务端证书校验；仅供测试集群使用。'
  fi
  [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]] ||
    op_fail 'install-addons 必须在新集群首个主节点上以 root 执行。' \
      '登录 Linux 主节点后使用 sudo 运行。'
  [[ "$(uname -m)" == x86_64 ]] ||
    op_fail '当前组件离线镜像包仅提供 linux/amd64。' \
      '准备同架构的 Chart、Helm 和全部镜像后重试。'
  require_bundle
  helm_archive="$BUNDLE_DIR/bin/helm-v3.21.0-linux-amd64.tar.gz"
  cilium_chart="$BUNDLE_DIR/charts/cilium-1.19.4.tgz"
  ingress_chart="$BUNDLE_DIR/charts/ingress-nginx-4.15.1.tgz"
  metrics_chart="$BUNDLE_DIR/charts/metrics-server-3.13.1.tgz"
  nfs_chart="$BUNDLE_DIR/charts/csi-driver-nfs-4.13.6.tgz"
  cilium_values="$BUNDLE_DIR/values/cilium-values.yaml"
  ingress_values="$BUNDLE_DIR/values/ingress-nginx-values.yaml"
  require_file "$helm_archive"
  chart_metadata "$cilium_chart" cilium 1.19.4
  chart_metadata "$ingress_chart" ingress-nginx 4.15.1
  chart_metadata "$metrics_chart" metrics-server 3.13.1
  chart_metadata "$nfs_chart" csi-driver-nfs 4.13.6
  require_file "$cilium_values"
  require_file "$ingress_values"

  # Validate every archive before the first ctr import or Helm release.
  require_oci_ref "$BUNDLE_DIR/images/cilium.tar" 'quay.io/cilium/cilium:v1.19.4'
  require_oci_ref "$BUNDLE_DIR/images/cilium-operator.tar" 'quay.io/cilium/operator-generic:v1.19.4'
  require_oci_ref "$BUNDLE_DIR/images/cilium-envoy.tar" 'quay.io/cilium/cilium-envoy:v1.36.6-1778235340-b87d1e32f522b33bd51701c6476d199326f01496'
  require_oci_ref "$BUNDLE_DIR/images/ingress-nginx-controller.tar" 'swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/ingress-nginx/controller:v1.15.1'
  require_oci_ref "$BUNDLE_DIR/images/ingress-nginx-webhook-certgen.tar" 'swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9'
  addon_tar="$BUNDLE_DIR/images/k8s-addon-images-amd64.tar"
  require_file "$addon_tar"
  image_manifest="$(bundle_image_file k8s-addon-images-amd64.json k8s-addon-images-amd64.json)"
  require_file "$image_manifest"
  command -v sha256sum >/dev/null 2>&1 ||
    op_fail '缺少 sha256sum，无法验证离线镜像归档。' \
      '安装 coreutils 后重新执行。'
  expected_sha="$(sed -n 's/^[[:space:]]*"archive_sha256": "\([0-9a-f]*\)".*/\1/p' "$image_manifest")"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] ||
    op_fail '新增镜像清单缺少有效 archive_sha256。' \
      '在联网准备机重新制作镜像归档和 JSON 清单。'
  actual_sha="$(sha256sum "$addon_tar")"
  actual_sha="${actual_sha%% *}"
  [[ "$actual_sha" == "$expected_sha" ]] ||
    op_fail '新增组件离线镜像归档 SHA256 不匹配。' \
      '重新复制归档与对应 JSON 清单，避免混用版本。'
  image_index="$(tar -xOf "$addon_tar" index.json 2>/dev/null)" ||
    op_fail '新增组件镜像归档不可读取。' '核对 OCI tar 完整性。'
  [[ "$image_index" == *'registry.k8s.io/metrics-server/metrics-server:v0.8.1'* ]] ||
    op_fail '新增组件镜像归档缺少 metrics-server:v0.8.1。' \
      '重新运行联网准备机上的镜像打包脚本。'
  for image in nfsplugin:v4.13.6 csi-provisioner:v6.3.0 csi-resizer:v2.2.1 csi-snapshotter:v8.6.0 livenessprobe:v2.19.0 csi-node-driver-registrar:v2.17.0; do
    [[ "$image_index" == *"registry.k8s.io/sig-storage/$image"* ]] ||
      op_fail "新增组件镜像归档缺少 ${image}。" \
        '重新运行联网准备机上的镜像打包脚本。'
  done

  command -v kubectl >/dev/null 2>&1 || op_fail '缺少 kubectl。' \
    '在 Sealos 新建的主节点运行；核对 /etc/kubernetes/admin.conf。'
  command -v ctr >/dev/null 2>&1 || op_fail '缺少 ctr，无法导入离线镜像。' \
    '核对 Sealos 安装的 containerd/ctr 是否完整。'
  command -v ss >/dev/null 2>&1 || op_fail '缺少 ss，无法验证 Ingress 主机端口。' \
    '安装 iproute/iproute2 后重试。'
  command -v mount.nfs >/dev/null 2>&1 || op_fail '缺少 NFS 客户端 mount.nfs。' \
    '从同版同架构系统准备 nfs-utils 或 nfs-common 及全部依赖。' \
    '用包内 install-host-packages-offline.sh --check/--install 本地安装。' \
    '完成后用 command -v mount.nfs 复查；不需要 NFS Server。'
  [[ -r "$KUBECONFIG_PATH" ]] || op_fail "kubeconfig 不可读：$KUBECONFIG_PATH" \
    '核对 Sealos 新集群的 admin.conf 路径。'
  if [[ -z "$KUBE_CONTEXT" ]]; then
    KUBE_CONTEXT="$(kubectl --kubeconfig "$KUBECONFIG_PATH" \
      config current-context 2>/dev/null)" ||
      op_fail 'kubeconfig 没有当前 context。' '使用 --context 显式指定。'
  fi
  uid="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
    get namespace kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)" ||
    op_fail '无法访问指定 Kubernetes 集群。' \
      '核对 kubeconfig、context 和 API Server。'
  marker="$STATE_DIR/cluster.uid"
  [[ -s "$marker" ]] || op_fail '未找到本脚本新建集群的标记，停止安装组件。' \
    '先在空白主机运行 install-k8s。' \
    '不要把此入口用于其他已有集群。'
  [[ "$(<"$marker")" == "$uid" ]] ||
    op_fail '当前 kubeconfig 指向的集群与新建集群标记不一致。' \
      '核对 --kubeconfig 和 --context，避免修改其他集群。'
  require_oci_digest "$BUNDLE_DIR/images/cilium.tar" \
    'sha256:2eb67991eaa9368ba199c2fac2c573cb0ffdeb79184533344f42fc9a7ff6af3c'
  require_oci_digest "$BUNDLE_DIR/images/cilium-operator.tar" \
    'sha256:1aa2b62735e7d8ab49ee840ae59c346932024c88901579121395c1271b435f71'
  require_oci_digest "$BUNDLE_DIR/images/cilium-envoy.tar" \
    'sha256:71d4fa0ec45e8d546dbd5604e169dc77fe92be63b799313bff031d00d89762e3'
  [[ "$(kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
    get nodes -o name 2>/dev/null | wc -l | tr -d ' ')" == 1 ]] ||
    op_fail '此安装流程仅支持本脚本新建的单节点集群。' \
      '确认节点数量后选择对应多节点安装方案。'
  if kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
       get daemonsets -A -o name 2>/dev/null |
       grep -Ei 'calico|flannel|weave' >/dev/null; then
    op_fail '检测到其他 CNI，停止 Cilium 安装。' \
      '核对现有网络插件及集群来源。'
  fi

  workdir="$(mktemp -d /tmp/sealos-k8s-addons.XXXXXX)" ||
    op_fail '无法创建临时目录。' '核对 /tmp 空间与权限。'
  trap "rm -rf -- $(printf '%q' "$workdir")" EXIT
  tar -xzf "$helm_archive" -C "$workdir" linux-amd64/helm ||
    op_fail '解压离线 Helm 失败。' '核对 Helm 压缩包完整性。'
  helm_bin="$workdir/linux-amd64/helm"
  "$helm_bin" template cilium "$cilium_chart" -n kube-system \
    -f "$cilium_values" > "$workdir/cilium.yaml" ||
    op_fail 'Cilium Chart 渲染失败。' '核对 values 与版本。'
  "$helm_bin" template ingress-nginx "$ingress_chart" -n ingress-nginx \
    -f "$ingress_values" > "$workdir/ingress.yaml" ||
    op_fail 'Ingress Chart 渲染失败。' '核对 values 与版本。'
  "$helm_bin" template metrics-server "$metrics_chart" -n kube-system \
    "${metrics_tls_args[@]}" > "$workdir/metrics.yaml" ||
    op_fail 'Metrics Server Chart 渲染失败。' '核对 Chart 版本。'
  "$helm_bin" template csi-driver-nfs "$nfs_chart" -n kube-system \
    --set controller.runOnControlPlane=true --set controller.replicas=1 \
    > "$workdir/nfs.yaml" ||
    op_fail 'CSI Driver NFS Chart 渲染失败。' '核对 Chart 版本。'
  expected_images="$workdir/expected-images.txt"
  rendered_images="$workdir/rendered-images.txt"
  cat > "$expected_images" <<'EXPECTED_IMAGES'
quay.io/cilium/cilium-envoy:v1.36.6-1778235340-b87d1e32f522b33bd51701c6476d199326f01496@sha256:71d4fa0ec45e8d546dbd5604e169dc77fe92be63b799313bff031d00d89762e3
quay.io/cilium/cilium:v1.19.4@sha256:2eb67991eaa9368ba199c2fac2c573cb0ffdeb79184533344f42fc9a7ff6af3c
quay.io/cilium/operator-generic:v1.19.4@sha256:1aa2b62735e7d8ab49ee840ae59c346932024c88901579121395c1271b435f71
registry.k8s.io/metrics-server/metrics-server:v0.8.1
registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.17.0
registry.k8s.io/sig-storage/csi-provisioner:v6.3.0
registry.k8s.io/sig-storage/csi-resizer:v2.2.1
registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0
registry.k8s.io/sig-storage/livenessprobe:v2.19.0
registry.k8s.io/sig-storage/nfsplugin:v4.13.6
swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/ingress-nginx/controller:v1.15.1
swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9
EXPECTED_IMAGES
  LC_ALL=C sort -u "$expected_images" -o "$expected_images"
  awk '$1 == "image:" { gsub(/["\047]/, "", $2); if ($2 != "") print $2 }' \
    "$workdir/cilium.yaml" "$workdir/ingress.yaml" \
    "$workdir/metrics.yaml" "$workdir/nfs.yaml" |
    LC_ALL=C sort -u > "$rendered_images"
  if ! cmp -s "$expected_images" "$rendered_images"; then
    diff -u "$expected_images" "$rendered_images" >&2 || true
    op_fail 'Chart 渲染镜像与离线归档的 12 个固定引用不一致。' \
      '核对上述差异；按当前 Chart/values 重新制作所有镜像归档。' \
      '不要让安装过程从外网补拉镜像。'
  fi
  if chart_uses_always_pull "$workdir"/{cilium,ingress,metrics,nfs}.yaml; then
    op_fail 'Chart 使用 imagePullPolicy: Always，离线节点可能访问镜像仓库。' \
      '在对应 values 中改为 IfNotPresent，并重新渲染、检查镜像归档。'
  fi
  if ! "$helm_bin" --kubeconfig "$KUBECONFIG_PATH" --kube-context "$KUBE_CONTEXT" \
       status ingress-nginx -n ingress-nginx >/dev/null 2>&1; then
    output="$(ss -H -lnt 2>/dev/null || true)"
    if port_listening "$output" 80 || port_listening "$output" 443; then
      op_fail 'Ingress 使用 hostNetwork，但本机 TCP 80/443 已被占用。' \
        '用 ss -lntp 查看进程；调整占用服务或修改 Ingress values。'
    fi
  fi

  op_line PASS '四个 Chart 的渲染镜像与离线归档的 12 个引用一致，目标集群已核对。'
  for image in cilium cilium-operator cilium-envoy ingress-nginx-controller ingress-nginx-webhook-certgen; do
    ctr -n k8s.io images import "$BUNDLE_DIR/images/$image.tar" ||
      op_fail "导入离线镜像失败：$image" \
        '核对镜像 tar、架构和 containerd 空间。'
  done
  ctr -n k8s.io images import "$addon_tar" ||
    op_fail '导入 Metrics Server/CSI NFS 镜像失败。' \
      '核对归档完整性、架构和 containerd 空间。'
  imported_refs="$(ctr -n k8s.io images list -q)" ||
    op_fail '无法读取 containerd 的 k8s.io 镜像清单。' \
      '用 ctr -n k8s.io images list 核对运行时状态。'
  for ref in \
    'quay.io/cilium/cilium:v1.19.4' \
    'quay.io/cilium/operator-generic:v1.19.4' \
    'quay.io/cilium/cilium-envoy:v1.36.6-1778235340-b87d1e32f522b33bd51701c6476d199326f01496' \
    'swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/ingress-nginx/controller:v1.15.1' \
    'swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9' \
    'registry.k8s.io/metrics-server/metrics-server:v0.8.1' \
    'registry.k8s.io/sig-storage/nfsplugin:v4.13.6' \
    'registry.k8s.io/sig-storage/csi-provisioner:v6.3.0' \
    'registry.k8s.io/sig-storage/csi-resizer:v2.2.1' \
    'registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0' \
    'registry.k8s.io/sig-storage/livenessprobe:v2.19.0' \
    'registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.17.0'; do
    grep -Fxq "$ref" <<<"$imported_refs" ||
      op_fail "containerd 中缺少镜像：$ref" \
        '检查 ctr 导入日志与 OCI 归档中的镜像引用。'
  done
  op_line PASS '12 个组件镜像均已在 containerd/k8s.io 核对。'

  op_line INFO '安装 Cilium 1.19.4。'
  "$helm_bin" --kubeconfig "$KUBECONFIG_PATH" --kube-context "$KUBE_CONTEXT" \
    upgrade --install cilium "$cilium_chart" -n kube-system \
    -f "$cilium_values" --wait --atomic --timeout 10m ||
    op_fail 'Cilium 安装失败，后续组件未安装。' \
      '检查 helm status cilium -n kube-system 与 Cilium Pod 日志。'
  kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
    wait nodes --all --for=condition=Ready --timeout=10m ||
    op_fail 'Cilium 已安装，但节点未达到 Ready。' \
      '检查 kubectl -n kube-system get pods -o wide。'
  op_line PASS 'Cilium 已安装，节点 Ready。'

  # One-node clusters need ordinary workloads schedulable on the only node.
  node="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
    get nodes -o jsonpath='{.items[0].metadata.name}')"
  op_line INFO "允许普通工作负载调度到单节点控制平面：${node}。"
  taints="$(kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
    get node "$node" -o jsonpath='{.spec.taints[*].key}')" ||
    op_fail '无法读取单节点 taint。' '检查节点状态与 API。'
  for taint in node-role.kubernetes.io/control-plane node-role.kubernetes.io/master; do
    if [[ " $taints " == *" $taint "* ]]; then
      kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
        taint node "$node" "$taint-" ||
        op_fail "无法移除单节点 taint：$taint" \
          '先核对节点调度策略及管理员权限。'
    fi
  done

  op_line INFO '安装 ingress-nginx 4.15.1（hostNetwork 80/443）。'
  "$helm_bin" --kubeconfig "$KUBECONFIG_PATH" --kube-context "$KUBE_CONTEXT" \
    upgrade --install ingress-nginx "$ingress_chart" -n ingress-nginx \
    --create-namespace -f "$ingress_values" --wait --atomic --timeout 10m ||
    op_fail 'ingress-nginx 安装失败，后续组件未安装。' \
      '检查 helm status ingress-nginx -n ingress-nginx 与 80/443 占用。'
  op_line PASS 'ingress-nginx 已安装。'

  op_line INFO '安装 metrics-server 3.13.1。'
  "$helm_bin" --kubeconfig "$KUBECONFIG_PATH" --kube-context "$KUBE_CONTEXT" \
    upgrade --install metrics-server "$metrics_chart" -n kube-system \
    "${metrics_tls_args[@]}" --wait --atomic --timeout 10m ||
    op_fail 'metrics-server 安装失败，后续组件未安装。' \
      '检查 Deployment、APIService 与 kubelet 证书。'
  metrics_ready=0
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
         get --raw=/apis/metrics.k8s.io/v1beta1/nodes >/dev/null 2>&1; then
      metrics_ready=1
      break
    fi
    sleep 5
  done
  ((metrics_ready)) || op_fail 'metrics-server Deployment 已安装，但 Metrics API 不可用。' \
    '检查 kubectl get apiservice v1beta1.metrics.k8s.io。' \
    '检查 metrics-server Pod 日志与 kubelet 证书。'
  op_line PASS 'metrics-server 已安装，Metrics API 可访问。'

  op_line INFO '安装 csi-driver-nfs 4.13.6。'
  "$helm_bin" --kubeconfig "$KUBECONFIG_PATH" --kube-context "$KUBE_CONTEXT" \
    upgrade --install csi-driver-nfs "$nfs_chart" -n kube-system \
    --set controller.runOnControlPlane=true --set controller.replicas=1 \
    --wait --atomic --timeout 10m ||
    op_fail 'csi-driver-nfs 安装失败。' \
      '检查 CSI Controller/Node Pod 和 NFS 客户端工具。'
  kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" \
    get csidriver nfs.csi.k8s.io >/dev/null ||
    op_fail 'Helm 已完成，但 nfs.csi.k8s.io 未注册。' \
      '检查 CSI Driver Pod 与 CSIDriver 对象。'
  op_line PASS 'csi-driver-nfs 已安装并注册。'
  op_line PASS '四个离线 Helm 组件安装完成。'
  op_line INFO 'NFS CSI Driver 不创建 NFS 服务端；StorageClass 需填写实际 server/share。'
}

reset_k8s_main() {
  local bundle_root clusterfile actual_uid node_count node_ip pvc_names pv_names
  local audit_root audit_dir timestamp free_kib required_file listeners port
  local residue='' old_path service process interface cluster_hosts other_endpoint rules
  local preflight_dir bundled_sealos helm_bin cluster_image_tar image_manifest addon_tar image_index
  local expected_sha actual_sha image
  local reset_failed=0
  parse_install_args reset-k8s "$@"
  [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]] ||
    op_fail 'reset-k8s 必须在目标 Linux 主节点上以 root 执行。' \
      '登录目标节点后使用 sudo 运行。'
  [[ "$(uname -m)" == x86_64 ]] ||
    op_fail '当前重装离线包仅支持 linux/amd64。' \
      '在同架构主机准备完整离线包。'
  command -v sha256sum >/dev/null 2>&1 ||
    op_fail '缺少 sha256sum，无法校验重装离线包。' \
      '安装 coreutils 后重试。'
  require_bundle
  case "$BUNDLE_DIR/" in
    /var/lib/*|/etc/kubernetes/*|/etc/cni/*|/root/.sealos/*|/tmp/*)
      op_fail '离线包位于可能被重置清理的目录。' \
        '将整个 sealos-k8s-offline 目录复制到 /opt/sealos-k8s-offline。' ;;
  esac
  bundle_root="$(dirname "$BUNDLE_DIR")"
  [[ -r "$bundle_root/SHA256SUMS" ]] ||
    op_fail '完整离线包缺少 SHA256SUMS。' \
      '先解压 sealos-k8s-offline-amd64.tar，再传输完整目录。'
  cluster_image_tar="$(bundle_image_file kubernetes-v1.33.6.tar sealos-images/kubernetes-v1.33.6.tar)"
  image_manifest="$(bundle_image_file k8s-addon-images-amd64.json k8s-addon-images-amd64.json)"
  for required_file in "$cluster_image_tar" "$image_manifest"; do
    require_file "$required_file"
    # Check coverage of the selected path after the digest and two separators.
    awk -v path="${required_file#"$bundle_root/"}" \
      'substr($0, 67) == path { found=1 } END { exit !found }' "$bundle_root/SHA256SUMS" ||
      op_fail "SHA256SUMS 未记录当前离线文件：$required_file" \
        '将完整离线包解压到全新目录后重试。'
  done
  for required_file in \
    bin/sealos_5.1.1_linux_amd64.tar.gz \
    bin/helm-v3.21.0-linux-amd64.tar.gz \
    charts/cilium-1.19.4.tgz \
    charts/ingress-nginx-4.15.1.tgz \
    charts/metrics-server-3.13.1.tgz \
    charts/csi-driver-nfs-4.13.6.tgz \
    values/cilium-values.yaml \
    values/ingress-nginx-values.yaml \
    images/cilium.tar \
    images/cilium-operator.tar \
    images/cilium-envoy.tar \
    images/ingress-nginx-controller.tar \
    images/ingress-nginx-webhook-certgen.tar \
    images/k8s-addon-images-amd64.tar; do
    require_file "$BUNDLE_DIR/$required_file"
  done
  (cd "$bundle_root" && sha256sum -c SHA256SUMS >/dev/null) ||
    op_fail '离线包 SHA256 校验失败，停止清理。' \
      "在 $bundle_root 执行 sha256sum -c SHA256SUMS 找出损坏文件。"
  op_line PASS '完整离线包已通过 SHA256 校验。'
  require_oci_ref "$cluster_image_tar" "$K8S_IMAGE_REF"
  require_cluster_image_amd64 "$cluster_image_tar"
  chart_metadata "$BUNDLE_DIR/charts/cilium-1.19.4.tgz" cilium 1.19.4
  chart_metadata "$BUNDLE_DIR/charts/ingress-nginx-4.15.1.tgz" ingress-nginx 4.15.1
  chart_metadata "$BUNDLE_DIR/charts/metrics-server-3.13.1.tgz" metrics-server 3.13.1
  chart_metadata "$BUNDLE_DIR/charts/csi-driver-nfs-4.13.6.tgz" csi-driver-nfs 4.13.6
  require_oci_ref "$BUNDLE_DIR/images/cilium.tar" 'quay.io/cilium/cilium:v1.19.4'
  require_oci_ref "$BUNDLE_DIR/images/cilium-operator.tar" 'quay.io/cilium/operator-generic:v1.19.4'
  require_oci_ref "$BUNDLE_DIR/images/cilium-envoy.tar" 'quay.io/cilium/cilium-envoy:v1.36.6-1778235340-b87d1e32f522b33bd51701c6476d199326f01496'
  require_oci_ref "$BUNDLE_DIR/images/ingress-nginx-controller.tar" \
    'swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/ingress-nginx/controller:v1.15.1'
  require_oci_ref "$BUNDLE_DIR/images/ingress-nginx-webhook-certgen.tar" \
    'swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9'
  addon_tar="$BUNDLE_DIR/images/k8s-addon-images-amd64.tar"
  expected_sha="$(sed -n 's/^[[:space:]]*"archive_sha256": "\([0-9a-f]*\)".*/\1/p' "$image_manifest")"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] ||
    op_fail '新增组件镜像清单的 SHA256 无效。' '重新准备完整离线包。'
  actual_sha="$(sha256sum "$addon_tar")"
  [[ "${actual_sha%% *}" == "$expected_sha" ]] ||
    op_fail '新增组件镜像归档摘要不匹配。' '重新复制完整离线包。'
  image_index="$(tar -xOf "$addon_tar" index.json 2>/dev/null)" ||
    op_fail '新增组件 OCI 索引不可读。' '重新复制完整离线包。'
  for image in \
    registry.k8s.io/metrics-server/metrics-server:v0.8.1 \
    registry.k8s.io/sig-storage/nfsplugin:v4.13.6 \
    registry.k8s.io/sig-storage/csi-provisioner:v6.3.0 \
    registry.k8s.io/sig-storage/csi-resizer:v2.2.1 \
    registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0 \
    registry.k8s.io/sig-storage/livenessprobe:v2.19.0 \
    registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.17.0; do
    [[ "$image_index" == *"$image"* ]] ||
      op_fail "新增组件归档缺少 $image。" '重新准备镜像归档。'
  done
  preflight_dir="$(mktemp -d /tmp/sealos-reset-preflight.XXXXXX)" ||
    op_fail '无法创建离线制品预检临时目录。' '核对 /tmp 空间。'
  trap "rm -rf -- $(printf '%q' "$preflight_dir")" EXIT
  tar -xzf "$BUNDLE_DIR/bin/sealos_5.1.1_linux_amd64.tar.gz" \
    -C "$preflight_dir" sealos ||
    op_fail '无法解压离线 Sealos CLI。' '重新准备压缩包。'
  bundled_sealos="$preflight_dir/sealos"
  [[ "$(sealos_cli_version "$bundled_sealos")" == 5.1.1 ]] ||
    op_fail '离线 Sealos CLI 版本不是 5.1.1。' '重新准备正确版本。'
  tar -xzf "$BUNDLE_DIR/bin/helm-v3.21.0-linux-amd64.tar.gz" \
    -C "$preflight_dir" linux-amd64/helm ||
    op_fail '无法解压离线 Helm CLI。' '重新准备压缩包。'
  helm_bin="$preflight_dir/linux-amd64/helm"
  [[ "$("$helm_bin" version --short 2>/dev/null)" == v3.21.0* ]] ||
    op_fail '离线 Helm CLI 版本不是 3.21.0。' '重新准备正确版本。'
  "$helm_bin" template cilium "$BUNDLE_DIR/charts/cilium-1.19.4.tgz" \
    -n kube-system -f "$BUNDLE_DIR/values/cilium-values.yaml" >/dev/null ||
    op_fail '离线 Cilium Chart 无法渲染。' '核对 Chart 和 values。'
  "$helm_bin" template ingress-nginx "$BUNDLE_DIR/charts/ingress-nginx-4.15.1.tgz" \
    -n ingress-nginx -f "$BUNDLE_DIR/values/ingress-nginx-values.yaml" >/dev/null ||
    op_fail '离线 Ingress Chart 无法渲染。' '核对 Chart 和 values。'
  "$helm_bin" template metrics-server "$BUNDLE_DIR/charts/metrics-server-3.13.1.tgz" \
    -n kube-system >/dev/null ||
    op_fail '离线 Metrics Server Chart 无法渲染。' '核对 Chart 版本。'
  "$helm_bin" template csi-driver-nfs "$BUNDLE_DIR/charts/csi-driver-nfs-4.13.6.tgz" \
    -n kube-system --set controller.runOnControlPlane=true \
    --set controller.replicas=1 >/dev/null ||
    op_fail '离线 CSI Driver NFS Chart 无法渲染。' '核对 Chart 版本。'
  op_line PASS 'ClusterImage、Sealos/Helm CLI、四个 Chart 和 12 个镜像引用已预检。'

  command -v ip >/dev/null 2>&1 || op_fail '缺少 ip，无法核对本机地址。' \
    '安装 iproute/iproute2 后重试。'
  ip -o -4 addr show 2>/dev/null | grep -F "inet $MASTER_IP/" >/dev/null ||
    op_fail "目标 IP $MASTER_IP 不在本机网卡上。" \
      '用 ip -4 addr show 核对实际私网 IP。'
  command -v kubectl >/dev/null 2>&1 || op_fail '缺少 kubectl。' \
    '先确认现有集群的管理工具可用。'
  [[ -r /etc/kubernetes/admin.conf ]] ||
    op_fail '现有集群 admin.conf 不可读。' \
      '确认这是要重装的 Sealos 主节点。'
  actual_uid="$(kubectl --kubeconfig /etc/kubernetes/admin.conf \
    get namespace kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null)" ||
    op_fail '无法从本机 admin.conf 读取集群 UID。' \
      '先检查现有控制面，不要盲目重置。'
  [[ -n "$actual_uid" && "$actual_uid" == "$EXPECT_CLUSTER_UID" ]] ||
    op_fail "集群 UID 不匹配：实际为 ${actual_uid:-空}。" \
      '用 kubectl --kubeconfig /etc/kubernetes/admin.conf get ns kube-system -o jsonpath={.metadata.uid} 核对。' \
      '确认目标集群后重新传 --expect-cluster-uid。'
  node_count="$(kubectl --kubeconfig /etc/kubernetes/admin.conf \
    get nodes -o name 2>/dev/null | wc -l | tr -d ' ')" ||
    op_fail '无法读取现有集群节点。' '核对 API Server 状态。'
  [[ "$node_count" == 1 ]] || op_fail "现有集群有 $node_count 个节点，拒绝单节点重置。" \
    '逐节点核对并使用对应的多节点清理方案。'
  node_ip="$(kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)" ||
    op_fail '无法取得现有节点 InternalIP。' '核对节点状态。'
  [[ "$node_ip" == "$MASTER_IP" ]] ||
    op_fail "集群节点 IP $node_ip 与 --master-ip $MASTER_IP 不一致。" \
      '确认云主机和 kubeconfig 指向同一集群。'
  clusterfile=/root/.sealos/default/Clusterfile
  [[ -r "$clusterfile" ]] || op_fail '缺少 Sealos default Clusterfile。' \
    '确认集群确由 Sealos 管理，不要使用此入口重置其他集群。'
  grep -Fxq '  name: default' "$clusterfile" ||
    op_fail 'Sealos Clusterfile 不是 default 集群。' '核对 Sealos 集群名称。'
  cluster_hosts="$(awk '
    /^  hosts:/ { in_hosts=1; next }
    in_hosts && /^  [A-Za-z]/ { exit }
    in_hosts && /^[[:space:]]*-[[:space:]]*ips:/ { in_ips=1; next }
    in_hosts && in_ips && /^[[:space:]]*roles:/ { in_ips=0; next }
    in_hosts && in_ips && /^[[:space:]]*-[[:space:]]*[^[:space:]]+/ { print $2 }
  ' "$clusterfile")"
  [[ "$cluster_hosts" == "$MASTER_IP:$SSH_PORT" ]] ||
    op_fail "Sealos Clusterfile 的 hosts 列表不是仅本机：${cluster_hosts:-空}。" \
      '核对 /root/.sealos/default/Clusterfile 的 spec.hosts。'
  other_endpoint="$(grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+' \
    "$clusterfile" | LC_ALL=C sort -u)"
  [[ "$other_endpoint" == "$MASTER_IP:$SSH_PORT" ]] ||
    op_fail 'Sealos Clusterfile 另有 IP:端口目标，停止整集群 reset。' \
      '核对 Sealos 配置中的 hosts 与 registry 主机。'
  command -v sealos >/dev/null 2>&1 || op_fail '缺少现有 Sealos CLI。' \
    '先核对现有集群的安装来源。'
  [[ "$(sealos_cli_version "$(command -v sealos)")" == 5.1.1 ]] ||
    op_fail '现有 Sealos CLI 不是 5.1.1，停止重置。' \
      '核对当前版本对应的 reset 语法和 Clusterfile。'
  require_ssh_login
  command -v mount.nfs >/dev/null 2>&1 ||
    op_fail '缺少重装 CSI NFS 所需的 mount.nfs。' \
      '先从同版系统准备 nfs-utils/nfs-common 的离线包及依赖。' \
      '用包内 install-host-packages-offline.sh 从本地安装后重试。'
  command -v ss >/dev/null 2>&1 ||
    op_fail '缺少 ss，无法复查 reset 后控制面端口。' \
      '安装 iproute/iproute2 后重试。'
  free_kib="$(df -Pk /var/lib | awk 'NR==2 {print $4}')"
  [[ "$free_kib" =~ ^[0-9]+$ ]] && ((free_kib >= 8*1024*1024)) ||
    op_fail '/var/lib 可用空间不足 8 GiB，停止重置。' \
      '用 df -h /var/lib 核对；扩容后再重试。'
  pvc_names="$(kubectl --kubeconfig /etc/kubernetes/admin.conf \
    get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null)" ||
    op_fail '无法列出现有 PVC。' '核对 API Server 状态。'
  pv_names="$(kubectl --kubeconfig /etc/kubernetes/admin.conf \
    get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)" ||
    op_fail '无法列出现有 PV。' '核对 API Server 状态。'
  if [[ "$RESET_DRY_RUN" == 1 ]]; then
    op_line PASS "reset-k8s 前提核对通过：集群 UID=$actual_uid，节点 IP=$node_ip。"
    if [[ -n "$pvc_names$pv_names" ]]; then
      op_line WARN "现有持久卷：PVC=${pvc_names:-无} PV=${pv_names:-无}；实际执行须确认数据影响。"
    else
      op_line INFO '现有集群没有 PV/PVC。'
    fi
    op_line INFO '这是 dry-run；没有执行 Sealos reset，也没有创建审计目录。'
    return 0
  fi
  if [[ -n "$pvc_names$pv_names" && "$ALLOW_STORAGE_LOSS" != 1 ]]; then
    op_fail "现有持久卷：PVC=${pvc_names:-无} PV=${pv_names:-无}。" \
      '重置可能删除卷声明，并按回收策略影响外部存储数据。' \
      '核对备份与实际数据后，明确传入 --allow-storage-loss。'
  fi

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  audit_root=/opt/sealos-preflight/reset-audit
  audit_dir="$audit_root/$timestamp-$actual_uid"
  (umask 077; mkdir -p "$audit_dir") ||
    op_fail '无法创建重置前审计目录。' '核对 /opt 空间与权限。'
  kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes,ns,pv,sc -o yaml \
    > "$audit_dir/cluster-resources.yaml" ||
    op_fail '无法保存节点、命名空间、PV、StorageClass 清单。' \
      '检查 API 后重试；尚未执行 reset。'
  kubectl --kubeconfig /etc/kubernetes/admin.conf get pvc -A -o yaml \
    > "$audit_dir/pvcs.yaml" ||
    op_fail '无法保存 PVC 清单。' '检查 API 后重试；尚未执行 reset。'
  kubectl --kubeconfig /etc/kubernetes/admin.conf get deploy,sts,ds,job -A -o yaml \
    > "$audit_dir/workloads.yaml" ||
    op_fail '无法保存工作负载清单。' '检查 API 后重试；尚未执行 reset。'
  cp -p "$clusterfile" "$audit_dir/Clusterfile" ||
    op_fail '无法保存 Sealos Clusterfile。' '核对审计目录权限。'
  scrub_clusterfile_ssh_password "$audit_dir/Clusterfile" ||
    op_fail '无法清除审计副本中的 SSH 密码。' \
      '立即限制审计目录权限并检查 Clusterfile。'
  if command -v helm >/dev/null 2>&1; then
    helm --kubeconfig /etc/kubernetes/admin.conf list -A > "$audit_dir/helm-releases.txt" ||
      op_fail '无法保存 Helm release 清单。' '检查 Helm 与 API 状态。'
  fi
  chmod -R go-rwx "$audit_dir" ||
    op_fail '无法保护审计文件权限。' '核对审计目录权限。'
  touch "$audit_dir/reset.start" ||
    op_fail '无法记录 reset 开始时间。' '核对审计目录权限。'
  op_line PASS "目标集群 UID、单节点 IP、自连接、离线包及重置前清单已核对；审计目录：$audit_dir"
  op_line INFO '开始 Sealos 5.1.1 reset；此操作会删除整个 default 集群。'
  if [[ "$SSH_AUTH" == password ]]; then
    prompt_ssh_password
    if ! sealos reset --cluster default --force --user root \
        --port "$SSH_PORT" --passwd "$SSH_PASSWORD" 2>&1 |
        redact_password_stream "$SSH_PASSWORD" | tee "$audit_dir/reset.log"; then
      reset_failed=1
    fi
    unset SSH_PASSWORD
    scrub_recent_clusterfiles "$audit_dir/reset.start" ||
      op_fail '无法清除 Sealos reset 后 Clusterfile 中的 SSH 密码。' \
        '立即以 root 检查 /root/.sealos/default/Clusterfile* 的权限和 spec.ssh.passwd。'
    ((reset_failed == 0)) || op_fail 'sealos reset 返回失败；未开始重装。' \
      '检查 Sealos 输出与审计目录；不要直接删除目录。'
  else
    sealos reset --cluster default --force --user "$SSH_USER" \
      --port "$SSH_PORT" --pk "$SSH_KEY" 2>&1 | tee "$audit_dir/reset.log" ||
      op_fail 'sealos reset 返回失败；未开始重装。' \
        '检查 Sealos 输出与审计目录；不要直接删除目录。'
  fi

  # Sealos 5.1.1 may log cleanup failures yet return zero. Verify the host.
  sleep 3
  if kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw=/readyz \
       >/dev/null 2>&1; then
    residue+=' Kubernetes API 仍可访问；'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    for service in kubelet containerd; do
      if systemctl is-active --quiet "$service"; then
        residue+=" $service 服务仍运行；"
      fi
    done
  fi
  if command -v containerd >/dev/null 2>&1 &&
     containerd --version >/dev/null 2>&1; then
    residue+=' containerd 二进制仍可执行；'
  fi
  if command -v pgrep >/dev/null 2>&1; then
    for process in kubelet containerd etcd kube-apiserver \
                   kube-controller-manager kube-scheduler; do
      if pgrep -x "$process" >/dev/null 2>&1; then
        residue+=" $process 进程仍运行；"
      fi
    done
  fi
  listeners="$(ss -H -lnt 2>/dev/null || true)"
  for port in 6443 2379 2380 10250 10257 10259; do
    if port_listening "$listeners" "$port"; then
      residue+=" TCP/$port 仍监听；"
    fi
  done
  for interface in cilium_host cilium_net kube-ipvs0; do
    if ip link show "$interface" >/dev/null 2>&1; then
      residue+=" $interface 网络接口仍存在；"
    fi
  done
  if command -v iptables-save >/dev/null 2>&1; then
    rules="$(iptables-save 2>/dev/null || true)"
    if grep -Eq '(^:|^-A )(KUBE-|CILIUM_)' <<<"$rules"; then
      residue+=' 仍有 KUBE-/CILIUM_ iptables 规则；'
    fi
  fi
  if command -v nft >/dev/null 2>&1; then
    rules="$(nft list ruleset 2>/dev/null || true)"
    if grep -Eq 'KUBE-|CILIUM_' <<<"$rules"; then
      residue+=' 仍有 KUBE-/CILIUM_ nftables 规则；'
    fi
  fi
  for old_path in /etc/kubernetes /etc/cni/net.d /var/lib/etcd \
                  /var/lib/kubelet /var/lib/containerd \
                  /var/lib/sealos/data/default \
                  /root/.sealos/default; do
    if [[ -d "$old_path" ]] &&
       [[ -n "$(find "$old_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      residue+=" $old_path 仍非空；"
    fi
  done
  [[ -z "$residue" ]] || op_fail "reset 后仍有残留：$residue" \
    '核对服务、目录和 Sealos 清理日志；不要在此状态直接运行 install-k8s。' \
    '若只剩旧 CNI/IPVS 网络对象，先确认没有其他集群使用，再定向清理或重启复查。' \
    "审计清单和 reset.log 保存在 $audit_dir；按实际归属处理残留后再检查。"
  rm -f "$STATE_DIR/cluster.uid" "$STATE_DIR/install.pending" 2>/dev/null ||
    op_fail '环境已清理，但无法移除旧集群标记。' \
      '核对 /var/lib/sealos-k8s-setup 权限。'
  op_line PASS 'Sealos/Kubernetes 旧集群已重置，主机清理检查通过。'
  op_line INFO "现在可运行 install-k8s --bundle-dir $BUNDLE_DIR --master-ip $MASTER_IP，然后运行 install-addons。"
}

if [[ "$CHECK_HOST_LIB_ONLY" == 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
  install-k8s) shift; install_k8s_main "$@"; exit 0 ;;
  install-addons) shift; install_addons_main "$@"; exit 0 ;;
  reset-k8s) shift; reset_k8s_main "$@"; exit 0 ;;
  check) shift ;;
esac

while (($#)); do
  case "$1" in
    --master-ip|--sealos-version|--ssh-user|--ssh-port|--ssh-auth|--cni)
      if (($#<2)) || [[ -z "$2" ]]; then
        printf '参数 %s 缺少值\n' "$1" >&2
        exit 2
      fi
      case "$1" in
        --master-ip) MASTER_IP="$2" ;;
        --sealos-version) SEALOS_VERSION="$2" ;;
        --ssh-user) SSH_USER="$2" ;;
        --ssh-port) SSH_PORT="$2" ;;
        --ssh-auth) SSH_AUTH="$2" ;;
        --cni) CNI="$2" ;;
      esac
      shift 2 ;;
    --ingress-hostnetwork) CHECK_INGRESS=1; shift ;;
    --check-nfs) CHECK_NFS=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$SEALOS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ||
      ! "$SSH_PORT" =~ ^[0-9]+$ ]] ||
   ((SSH_PORT<1 || SSH_PORT>65535)) ||
   [[ ! "$SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ||
      "$CNI" != cilium && "$CNI" != other ]] ||
   [[ "$SSH_AUTH" != key && "$SSH_AUTH" != password ]] ||
   [[ "$SSH_AUTH" == password && "$SSH_USER" != root ]]; then
  printf '版本、SSH 或 CNI 参数格式不正确。\n' >&2
  exit 2
fi

printf 'Sealos/Kubernetes 全新安装主机预检（只读）\n'
printf '目标 Sealos: %s；CNI: %s\n' "$SEALOS_VERSION" "$CNI"
printf 'SSH 认证方式: %s；用户: %s；端口: %s\n' "$SSH_AUTH" "$SSH_USER" "$SSH_PORT"
printf '附加检查: hostNetwork Ingress=%s，NFS=%s\n' "$CHECK_INGRESS" "$CHECK_NFS"

if [[ "$(uname -s 2>/dev/null)" != Linux ]]; then
  report FAIL '必须在目标 Linux 主机上运行。' LINUX
  print_summary
  exit 1
fi

if [[ "$(id -u)" != 0 ]]; then
  report WARN '当前不是 root，部分主机信息可能无法完整读取。' ROOT
fi

arch="$(uname -m 2>/dev/null)"
case "$arch" in
  x86_64|aarch64|arm64) report PASS "架构 ${arch}：Sealos 支持 amd64/arm64。" ;;
  *) report FAIL "架构 ${arch}：不在目标 Sealos 架构范围。" ARCH ;;
esac

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  case " $OS_ID ${ID_LIKE:-} " in
    *rhel*|*centos*|*rocky*|*fedora*) OS_FAMILY=rhel ;;
    *debian*|*ubuntu*) OS_FAMILY=debian ;;
  esac
  if os_policy "$OS_ID" "$OS_VERSION"; then
    report PASS "系统 ${PRETTY_NAME:-$OS_ID $OS_VERSION}：在当前检查范围。"
  else
    report WARN "系统 ${PRETTY_NAME:-$OS_ID $OS_VERSION}：需核对 Sealos 与所选 CNI 支持。" OS
  fi
else
  report FAIL '缺少 /etc/os-release，无法判定系统发行版。' OS
fi

if command -v nproc >/dev/null 2>&1; then
  cpus="$(nproc 2>/dev/null || true)"
  if [[ "$cpus" =~ ^[0-9]+$ ]]; then
    if ((cpus<2)); then
      report FAIL "控制平面可用 CPU=${cpus}，低于 kubeadm 2 CPU 起点。" CPU
    else
      report PASS "控制平面可用 CPU=${cpus}，达到 2 CPU 起点。"
    fi
  else
    report WARN '无法读取 CPU 数量。' CPU
  fi
else
  report WARN '缺少 nproc，无法读取 CPU 数量。' CMD nproc
fi

if [[ -r /proc/meminfo ]]; then
  mem_kib=0
  while read -r key value unit; do
    if [[ "$key" == MemTotal: ]]; then mem_kib="$value"; break; fi
  done < /proc/meminfo
  if [[ "$mem_kib" =~ ^[0-9]+$ ]]; then
    mem_gib=$((mem_kib/1024/1024))
    if ((mem_kib<2*1024*1024)); then
      report FAIL "内存约 $mem_gib GiB，低于 kubeadm 每节点 2 GiB 起点。" MEMORY
    elif ((mem_kib<4*1024*1024)); then
      report WARN "内存约 $mem_gib GiB：达到 2 GiB 起点，但余量偏少。" MEMORY low_margin
    else
      report PASS "内存约 $mem_gib GiB：达到基础安装起点。"
    fi
  else
    report WARN '无法读取 MemTotal。' MEMORY
  fi
else
  report WARN '无法读取 /proc/meminfo。' MEMORY
fi

if [[ -r /proc/cpuinfo ]]; then
  cpu_flags=""
  while IFS= read -r line; do
    case "$line" in
      flags[[:space:]]*:*|Features[[:space:]]*:*)
        cpu_flags="${line#*:}"; break ;;
    esac
  done < /proc/cpuinfo
  if [[ -n "$cpu_flags" ]]; then
    flag_line='CPU 指令集:'
    for feature in sse2 ssse3 sse4_1 sse4_2 avx avx2; do
      if [[ " $cpu_flags " == *" $feature "* ]]; then
        flag_line+=" $feature=Y"
      else
        flag_line+=" $feature=N"
      fi
    done
    report INFO "$flag_line"
    report INFO 'AVX/AVX2 仅供工作负载排查，Sealos/K8s 无统一硬门槛。'
  else
    report WARN '无法读取 CPU 指令标志。' CPU
  fi
fi

if command -v getconf >/dev/null 2>&1; then
  libc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
  if [[ "$libc" == glibc\ * ]]; then
    report PASS "$libc 可用。"
  else
    report FAIL "未确认兼容 glibc（结果: ${libc}）。" GLIBC
  fi
else
  report WARN '缺少 getconf，无法确认 glibc。' CMD getconf
fi

if [[ -r /proc/1/comm ]]; then
  read -r pid1 < /proc/1/comm
else
  pid1=""
fi
if [[ "$pid1" == systemd ]] && command -v systemctl >/dev/null 2>&1; then
  report PASS 'PID 1 是 systemd，服务管理可用。'
else
  report FAIL "PID 1=${pid1:-unknown}；目标集群镜像需要正常的 systemd 主机。" SYSTEMD
fi

if command -v findmnt >/dev/null 2>&1; then
  cgroup_fs="$(findmnt -rn --mountpoint /sys/fs/cgroup -o FSTYPE 2>/dev/null || true)"
  case "$cgroup_fs" in
    cgroup2|cgroup) report PASS "cgroup 挂载可用：${cgroup_fs}。" ;;
    tmpfs)
      if findmnt -rn -t cgroup -o TARGET 2>/dev/null | grep -q '/sys/fs/cgroup/'; then
        report PASS 'cgroup v1 控制器已挂载。'
      else
        report FAIL '未检测到 cgroup 控制器挂载。' CGROUP
      fi ;;
    *) report FAIL '未检测到可用 cgroup 挂载。' CGROUP ;;
  esac
else
  report WARN '缺少 findmnt，cgroup 挂载待核实。' CMD findmnt
fi

if [[ -r /proc/swaps ]] && [[ "$(wc -l </proc/swaps)" -gt 1 ]]; then
  report WARN '当前启用了 swap；默认 kubelet 会拒绝启动。' SWAP
else
  report PASS '未检测到启用的 swap。'
fi

if [[ -r /proc/sys/net/ipv4/ip_forward ]]; then
  read -r forward < /proc/sys/net/ipv4/ip_forward
  if [[ "$forward" == 1 ]]; then
    report PASS 'IPv4 转发已启用。'
  else
    report WARN 'IPv4 转发未启用，需按 CNI 网络设计处理。' FORWARD
  fi
else
  report WARN '无法读取 IPv4 转发状态。' FORWARD
fi

for module in overlay br_netfilter; do
  if [[ -d "/sys/module/$module" ]]; then
    report PASS "内核模块 $module 已加载。"
  elif command -v modprobe >/dev/null 2>&1 && modprobe -n "$module" >/dev/null 2>&1; then
    report PASS "内核模块 $module 可加载。"
  else
    report WARN "无法确认内核模块 $module 可用。" MODULE "$module"
  fi
done

release="$(uname -r 2>/dev/null)"
if [[ "$CNI" == cilium ]]; then
  if cilium_kernel_policy "$release" "$OS_ID" "$OS_VERSION"; then
    report PASS "内核 $release 满足 Cilium 1.19.4 的 5.10 基线或等效回移条件。"
  else
    report FAIL "内核 $release 未达到 Cilium 1.19.4 要求。" KERNEL
  fi
  cfg=""
  if [[ -r "/boot/config-$release" ]]; then
    cfg="$(<"/boot/config-$release")"
  elif [[ -r /proc/config.gz ]] && command -v gzip >/dev/null 2>&1; then
    cfg="$(gzip -cd /proc/config.gz 2>/dev/null || true)"
  fi
  if [[ -n "$cfg" ]]; then
    missing_cfg=""
    for option in BPF BPF_EVENTS BPF_SYSCALL NET_CLS_BPF BPF_JIT NET_CLS_ACT NET_SCH_INGRESS CRYPTO_SHA1 CRYPTO_USER_API_HASH CGROUPS CGROUP_BPF PERF_EVENTS SCHEDSTATS NETFILTER_XT_SET IP_SET IP_SET_HASH_IP NETFILTER_XT_MATCH_COMMENT VXLAN GENEVE FIB_RULES; do
      if [[ "$cfg" != *"CONFIG_$option=y"* && "$cfg" != *"CONFIG_$option=m"* ]]; then
        missing_cfg+=" CONFIG_$option"
      fi
    done
    if [[ -n "$missing_cfg" ]]; then
      report FAIL 'Cilium 所需内核配置有缺项。' KCONFIG "$missing_cfg"
    else
      report PASS 'Cilium eBPF、iptables 与隧道相关内核配置可用。'
    fi
  else
    report WARN "无法读取运行内核 $release 的配置，Cilium 功能未核实。" KCONFIG_UNKNOWN
  fi
else
  report INFO '未选择 Cilium；请按实际 CNI 文档核对内核和端口。'
fi

host_name="$(hostname 2>/dev/null || true)"
if [[ -z "$host_name" || "$host_name" == *"_"* ]]; then
  report FAIL "主机名 ${host_name:-empty} 不适合作为 Sealos 节点名。" HOSTNAME
else
  report PASS "主机名 $host_name 无下划线；跨节点唯一性仍需核对。"
fi
if [[ -r /sys/class/dmi/id/product_uuid ]]; then
  report INFO 'product_uuid 可读取；跨节点唯一性需在全部节点比较。'
fi

if command -v timedatectl >/dev/null 2>&1; then
  time_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "$time_sync" == yes ]]; then
    report PASS '本机时间已同步。'
  else
    report WARN "时间同步状态=${time_sync:-unknown}；需核对节点间时间。" TIME
  fi
else
  report WARN '缺少 timedatectl，时间同步未核实。' CMD timedatectl
fi

if command -v df >/dev/null 2>&1; then
  df_output="$(df -Pk / 2>/dev/null || true)"
  df_line="${df_output##*$'\n'}"
  read -r fs blocks used available usepct mountpoint <<<"$df_line"
  if [[ "$available" =~ ^[0-9]+$ ]]; then
    free_gib=$((available/1024/1024))
    if ((available<10*1024*1024)); then
      report WARN "根文件系统可用约 $free_gib GiB；建议核对集群镜像空间。" DISK_SPACE
    else
      report PASS "根文件系统可用约 $free_gib GiB；无固定 100 GB 硬门槛。"
    fi
  else
    report WARN '无法读取根文件系统可用空间。' DISK_SPACE
  fi
else
  report WARN '缺少 df，磁盘可用空间未核实。' CMD df
fi

for cmd in ip ss modprobe conntrack socat iptables; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    report WARN "命令 $cmd 缺失；按所选网络模式确认需求。" CMD "$cmd"
  fi
done

if [[ -n "$MASTER_IP" ]]; then
  if command -v ip >/dev/null 2>&1; then
    if ip -o -4 addr show 2>/dev/null | grep -F "inet $MASTER_IP/" >/dev/null; then
      report PASS "主节点私网 IP $MASTER_IP 已配置在本机。"
    else
      report FAIL "主节点 IP $MASTER_IP 未在本机网卡发现。" MASTER_IP
    fi
  else
    report WARN '缺少 ip，无法核对 --master-ip。' CMD ip
  fi
else
  report WARN '未传 --master-ip；节点私网 IP 尚未核对。' MASTER_IP
fi

listeners=""
if command -v ss >/dev/null 2>&1; then
  listeners="$(ss -H -lnt 2>/dev/null || true)"
fi
if command -v sshd >/dev/null 2>&1; then
  if sshd -t >/dev/null 2>&1; then
    if [[ -n "$listeners" ]] && port_listening "$listeners" "$SSH_PORT"; then
      report PASS "SSH 服务监听 TCP ${SSH_PORT}。"
    else
      report FAIL "未确认 SSH 服务监听 TCP ${SSH_PORT}。" SSH_SERVICE
    fi
    ssh_cfg="$(sshd -T 2>/dev/null || true)"
    permitrootlogin=""
    pubkeyauthentication=""
    passwordauthentication=""
    kbdinteractiveauthentication=""
    while read -r key value rest; do
      case "$key" in
        permitrootlogin) permitrootlogin="$value" ;;
        pubkeyauthentication) pubkeyauthentication="$value" ;;
        passwordauthentication) passwordauthentication="$value" ;;
        kbdinteractiveauthentication) kbdinteractiveauthentication="$value" ;;
      esac
    done <<<"$ssh_cfg"
    if [[ "$SSH_AUTH" == password ]]; then
      if [[ "$permitrootlogin" != yes ]]; then
        report FAIL "sshd 的 PermitRootLogin=${permitrootlogin:-未知}，不允许 root 密码认证。" SSH_AUTH
      elif [[ "$passwordauthentication" != yes ]]; then
        report FAIL 'sshd 未开放 SSH password 认证；Sealos 5.1.1 不使用 keyboard-interactive。' SSH_AUTH
      else
        report WARN 'sshd 允许 root 密码认证；实际凭据与私网链路仍需 SSH 自连接验证。' SSH_AUTH
      fi
    elif [[ "$SSH_USER" == root && ( "$permitrootlogin" == no || "$permitrootlogin" == forced-commands-only ) ]]; then
      report FAIL 'sshd 禁止当前 root 私钥方式执行 Sealos 命令。' SSH_AUTH
    elif [[ "$pubkeyauthentication" == no ]]; then
      report FAIL 'sshd 已关闭公钥认证；当前选择私钥方式。' SSH_AUTH
    else
      report WARN "sshd 允许候选私钥认证；实际 $SSH_USER 登录仍需 SSH 自连接验证。" SSH_AUTH
    fi
  else
    report FAIL 'sshd -t 校验失败，SSH 配置不可用。' SSH_SERVICE
  fi
else
  report FAIL '未找到 sshd；Sealos 多节点/--masters 模式需要 SSH。' SSH_SERVICE
fi

if [[ "$SSH_AUTH" == password ]]; then
  if [[ "$(id -u)" == 0 ]] && command -v passwd >/dev/null 2>&1; then
    passwd_output="$(LC_ALL=C passwd -S root 2>/dev/null || true)"
    passwd_state=''
    read -r _ passwd_state _ <<<"$passwd_output"
    case "$passwd_state" in
      P|PS) report PASS 'root 已设置本地密码；仍需实测 SSH 登录。' ;;
      L|LK|NP)
        report FAIL "root 密码状态为 $passwd_state，当前无法使用密码登录。" SSH_AUTH ;;
      *) report WARN '无法判定 root 密码状态；请实测 SSH 登录。' SSH_AUTH ;;
    esac
  else
    report WARN '无法读取 root 密码状态；请以 root 运行预检并实测登录。' SSH_AUTH
  fi
fi

existing_cluster=0
for path in /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kubelet.conf; do
  if [[ -f "$path" ]]; then
    existing_cluster=1
  fi
done
if ((existing_cluster)); then
  report FAIL '本机已有 Kubernetes 配置，不能作为新集群空白节点。' EXISTING_CLUSTER
else
  report PASS '未发现本机已有 Kubernetes 控制面/节点配置。'
fi
if command -v kubectl >/dev/null 2>&1; then
  node_line="$(kubectl get nodes --request-timeout=5s --no-headers 2>/dev/null | head -n 1 || true)"
  if [[ -n "$node_line" ]]; then
    report INFO "kubectl 可访问集群：$node_line"
  fi
fi

if command -v containerd >/dev/null 2>&1; then
  runtime_version="$(containerd --version 2>/dev/null || true)"
  if [[ -n "$runtime_version" ]]; then
    runtime_display="$runtime_version"
    if [[ "$runtime_version" =~ (v[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      runtime_display="${BASH_REMATCH[1]}"
    fi
    if [[ "$SEALOS_VERSION" == 5.1.1 ]]; then
      report FAIL "已安装 containerd ${runtime_display}；Sealos 5.1.1 新建集群会阻断。" CONTAINERD
    else
      report WARN "已安装 containerd ${runtime_display}；目标 Sealos 版本的处理需另核对。" CONTAINERD
    fi
  else
    report WARN '发现 containerd 命令，但 --version 未成功；需核对安装残留。' CONTAINERD version_failed
  fi
else
  report PASS '未预装 containerd；Sealos 集群镜像会准备运行时。'
fi
if command -v kubelet >/dev/null 2>&1 && ((existing_cluster==0)); then
  report WARN '存在 kubelet 可执行文件，但未发现集群配置；核对是否为旧安装残留。' EXISTING_CLUSTER
fi
if command -v sealos >/dev/null 2>&1; then
  sealos_version=""
  in_sealos_section=0
  while IFS= read -r line; do
    if [[ "$line" == SealosVersion: ]]; then
      in_sealos_section=1
    elif ((in_sealos_section)) && [[ "$line" == *gitVersion:* ]]; then
      sealos_version="${line##*: }"
      break
    fi
  done < <(sealos version 2>/dev/null)
  report INFO "已安装 Sealos CLI：${sealos_version:-版本未读到}。"
else
  report INFO '尚未安装 Sealos CLI；主机预检不要求预装。'
fi
if [[ "$SEALOS_VERSION" != 5.1.1 ]]; then
  report WARN "containerd 阻断规则按 Sealos 5.1.1 核实；目标版本 $SEALOS_VERSION 需单独确认。" SEALOS_VERSION
fi

if [[ -n "$listeners" ]]; then
  busy_ports=""
  for port in 6443 2379 2380 10250 10257 10259; do
    if port_listening "$listeners" "$port"; then busy_ports+=" $port"; fi
  done
  if [[ -n "$busy_ports" ]]; then
    if ((existing_cluster)); then
      report WARN "Kubernetes 控制面端口已监听:${busy_ports}；与现有集群一致。" PORT
    else
      report FAIL "新集群所需本机端口已占用:${busy_ports}。" PORT
    fi
  else
    report PASS '本机 Kubernetes 控制面端口未被监听。'
  fi
else
  report WARN '无法读取本机监听端口；端口冲突未核对。' PORT
fi

if ((CHECK_INGRESS)); then
  ingress_busy=""
  for port in 80 443; do
    if [[ -n "$listeners" ]] && port_listening "$listeners" "$port"; then
      ingress_busy+=" $port"
    fi
  done
  if [[ -n "$ingress_busy" ]]; then
    report FAIL "hostNetwork Ingress 端口已占用:${ingress_busy}。" INGRESS_PORT
  else
    report PASS 'hostNetwork Ingress 的 TCP 80/443 未被监听。'
  fi
else
  report INFO '未选择 hostNetwork Ingress；TCP 80/443 不作为硬条件。'
fi

if ((CHECK_NFS)); then
  if command -v mount.nfs >/dev/null 2>&1; then
    report PASS 'NFS 客户端 mount.nfs 可用。'
  else
    report FAIL '计划使用 NFS，但缺少客户端 mount.nfs。' NFS_CLIENT
  fi
else
  report INFO '未选择 NFS 存储；不检查 NFS 客户端 mount.nfs。'
fi

if command -v systemctl >/dev/null 2>&1 &&
   systemctl is-active --quiet firewalld.service; then
  report WARN 'firewalld 正在运行；需核对集群内网端口规则。' FIREWALL
fi
if command -v getenforce >/dev/null 2>&1; then
  report INFO "SELinux 状态: $(getenforce 2>/dev/null)。"
fi

report INFO '跨节点连通性、云安全组及镜像可用性需从实际环境验证。'
if [[ "$CNI" == cilium ]]; then
  report INFO '多节点 Cilium 端口按网络模式放通；VXLAN 常用 UDP 8472。'
fi
report INFO 'metrics-server 无统一额外宿主机软件包门槛，需安装后验证。'

print_summary
if ((FAIL_COUNT>0)); then exit 1; fi
exit 0
