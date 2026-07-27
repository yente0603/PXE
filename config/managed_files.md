# Managed Installation State

The `/opt/pxe/state` directory stores managed configuration and service states recorded after dependency installation but before PXE configuration is applied. It is used to restore the original system state during uninstallation.

- `original/`  
  Stores copies of managed files that existed before the first installation.

  Files retain their original absolute-path hierarchy. For example:

  ```text
  /opt/pxe/state/original/etc/netplan/02-pxe.yaml
  ```

  corresponds to:

  ```text
  /etc/netplan/02-pxe.yaml
  ```

- `absent/`  
  Stores markers for managed paths that did not exist before the first installation. The corresponding paths are removed during uninstallation.

- `apache/`  
  Stores the original enabled or disabled state of managed Apache sites and modules.

- `services/`  
  Stores the original enabled and active state of managed systemd services.

- `managed_files.list`  
  Lists the filesystem paths managed by the installer. These paths are checked when recording and restoring the original system state.

- `recorded`  
  A marker file indicating that the original system state has already been recorded. Later installations or upgrades must not overwrite the recorded state while this marker exists.

## Example File Tree (`/opt/pxe/state`)

The exact contents depend on the state of the system before the **first** installation.

```text
.
├── absent
│   ├── etc
│   │   ├── NetworkManager
│   │   │   └── dispatcher.d
│   │   │       └── 50-pxe-services
│   │   ├── apache2
│   │   │   └── sites-available
│   │   │       └── pxe_apache.conf
│   │   ├── netplan
│   │   │   └── 02-pxe.yaml
│   │   ├── radvd.conf
│   │   ├── sysctl.d
│   │   │   └── 99-pxe-ipv6.conf
│   │   └── systemd
│   │       └── system
│   │           └── pxe-mount.service
│   └── usr
│       └── local
│           └── lib
│               └── ipxe
│                   ├── ipxe-arm64.efi
│                   ├── ipxe-x86.efi
│                   ├── snp-arm64.efi
│                   └── undionly-legacy.kpxe
├── apache
│   ├── default-site
│   ├── headers-module
│   └── pxe-site
├── managed_files.list
├── original
│   └── etc
│       ├── default
│       │   ├── isc-dhcp-server
│       │   └── tftpd-hpa
│       └── dhcp
│           ├── dhcpd.conf
│           └── dhcpd6.conf
├── recorded
└── services
    ├── apache2.service.active
    ├── isc-dhcp-server.service.active
    ├── isc-dhcp-server6.service.active
    ├── pxe-mount.service.active
    ├── pxe-mount.service.enabled
    ├── radvd.service.active
    └── tftpd-hpa.service.active

21 directories, 26 files
```