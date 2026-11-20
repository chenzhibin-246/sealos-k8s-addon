# sealos-k8s-addon

使用 Sealos 部署单节点 Kubernetes 和离线插件。

## 内容

- `scripts/check-single-node-host.sh` 是 Sealos/Kubernetes Linux 主机只读预检脚本，默认检查 Sealos 5.1.1 和 Cilium 1.19.4 的主机条件。
- `sealos-k8s-offline-amd64.tar` 是 linux/amd64 离线包，包含 Sealos 5.1.1、Helm 3.21.0、Kubernetes v1.33.6 ClusterImage、Cilium、ingress-nginx、metrics-server 和 CSI Driver NFS 的离线制品。
- 大型离线包通过 GitHub Release 资产分发，仓库源码中保留 SHA256 清单和安装入口说明。

## 离线包校验

下载 Release 资产后执行：

```bash
shasum -a 256 sealos-k8s-offline-amd64.tar
cat sealos-k8s-offline-amd64.tar.sha256

tar -tf sealos-k8s-offline-amd64.tar | head
```

目标节点解包后，在包根目录执行：

```bash
sha256sum -c SHA256SUMS
bash check-single-node-host.sh check --master-ip <节点私网IP> --cni cilium
```

## 安装入口

在目标 Linux 主节点执行。Sealos 的 `--master-ip` 应使用节点实际私网地址。

```bash
cd /opt/sealos-k8s-offline
./check-single-node-host.sh install-k8s \\
  --bundle-dir /opt/sealos-k8s-offline/offline-bundle \\
  --master-ip <节点私网IP> \\
  --ssh-key /root/.ssh/id_sealos-install \\
  --ssh-user root --ssh-port 22 --ssh-auth key

./check-single-node-host.sh install-addons \\
  --bundle-dir /opt/sealos-k8s-offline/offline-bundle \\
  --kubeconfig /etc/kubernetes/admin.conf
```

如果测试集群的 kubelet serving 证书缺少节点 IP SAN，确认日志后可以显式使用 `--metrics-insecure-tls`。该参数会跳过 metrics-server 到 kubelet 的服务端证书校验，正式环境应先修复 kubelet serving 证书和可信 CA。

离线包不安装 NFS Server，也不创建带真实 `server/share` 的永久 StorageClass。CSI Driver NFS 需要按实际 NFS 服务端配置。
