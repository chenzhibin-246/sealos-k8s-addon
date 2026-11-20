# sealos-k8s-addon

使用 Sealos 部署单节点 Kubernetes 和离线插件。

## 内容

- [`scripts/check-single-node-host.sh`](scripts/check-single-node-host.sh) 是 Linux 主机预检脚本，默认检查 Sealos 5.1.1 和 Cilium 1.19.4 所需的环境。
- `sealos-k8s-offline-amd64.tar.gz` 是 linux/amd64 离线包，包含 Sealos 5.1.1、Helm 3.21.0、Kubernetes v1.33.6 ClusterImage、Cilium、ingress-nginx、metrics-server 和 CSI Driver NFS 的离线制品。

## 下载、校验和解包

从 [GitHub Release v1.0.0](https://github.com/chenzhibin-246/sealos-k8s-addon/releases/tag/v1.0.0) 下载 `sealos-k8s-offline-amd64.tar.gz`，并将 [SHA256 校验文件](sealos-k8s-offline-amd64.tar.gz.sha256) 放在同一目录。在目标 Linux 节点执行以下命令。

```bash
sha256sum -c sealos-k8s-offline-amd64.tar.gz.sha256
tar -xzf sealos-k8s-offline-amd64.tar.gz
cd sealos-k8s-offline
sha256sum -c SHA256SUMS
```

## 检查和安装

在上一步解包得到的 `sealos-k8s-offline` 目录中执行。将示例 `MASTER_IP` 和 `SSH_KEY` 替换为目标节点的实际私网地址和 Sealos 用于连接该节点的 SSH 私钥路径。

```bash
MASTER_IP=192.0.2.10
SSH_KEY=/root/.ssh/id_sealos-install

bash check-single-node-host.sh check --master-ip "$MASTER_IP" --cni cilium

sudo bash check-single-node-host.sh install-k8s \
  --bundle-dir "$PWD/offline-bundle" \
  --master-ip "$MASTER_IP" \
  --ssh-key "$SSH_KEY" \
  --ssh-user root --ssh-port 22 --ssh-auth key

sudo bash check-single-node-host.sh install-addons \
  --bundle-dir "$PWD/offline-bundle" \
  --kubeconfig /etc/kubernetes/admin.conf
```

如果测试集群的 kubelet serving 证书缺少节点 IP SAN，确认日志后可以显式使用 `--metrics-insecure-tls`。该参数会跳过 metrics-server 到 kubelet 的服务端证书校验，正式环境应先修复 kubelet serving 证书和可信 CA。

CSI Driver NFS 需要已有的 NFS Server 和使用实际 `server/share` 的 StorageClass。
