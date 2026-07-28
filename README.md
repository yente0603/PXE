# PXE

**Latest Version**: 3.0.1  
**Release Date**: 2026/07/28  
**Author**: Jasper Lee  

This project provides a repeatable PXE server setup for Ubuntu Desktop. It configures bridge networking, DHCP, TFTP, Apache HTTP, and iPXE for IPv4 and IPv6 network boot.

## Features

- IPv4 and IPv6 PXE boot support
- Automated PXE server installation
- Legacy BIOS, x86_64 UEFI, and ARM64 UEFI iPXE binaries
- Optional EFI Shell, WinPE, and Ghost assets
- ISO mount and unmount helpers
- Structured installation and operation logs
- State-aware uninstallation and original configuration restoration
- SHA-256 verification for the bundled iPXE source archive

## Compatibility

- Supports Ubuntu Desktop 22.04 LTS and later supported releases
- Requires NetworkManager
- Uses Netplan with the NetworkManager renderer
- Requires `sudo` because it modifies networking and system services

Server-only or heavily customized Ubuntu installations are not currently supported. Review the network configuration before running the installer.

## Configuration

1. Copy the sample configuration:

   ```bash
   cp config/pxe.conf.example config/pxe.conf
   ```

2. Edit `config/pxe.conf` and verify:

   - `PXE_INTERFACE`: physical PXE network interface
   - `PXE_BRIDGE`: PXE bridge name
   - IPv4 and IPv6 addresses, prefixes, and DHCP ranges
   - `ISO_PATH`: directory containing ISO files

Paths managed by the installation are stored under `/opt/pxe`.

## How to Run

Install the PXE server:

```bash
sudo ./pxe_installer.sh
```

Show available options:

```bash
sudo ./pxe_installer.sh --help
```

Common operations:

```bash
sudo ./pxe_installer.sh --mount
sudo ./pxe_installer.sh --umount
sudo ./pxe_installer.sh --uninstall
sudo ./pxe_installer.sh --no-ipxe-build
```

After installation, custom files can be edited at:

- iPXE menu: `/opt/pxe/tftp/ipxe/boot.ipxe`
- WinPE startup script: `/opt/pxe/http/winpe/startup.bat`
- Installed configuration: `/opt/pxe/config/pxe.conf`
- Operation logs: `/opt/pxe/logs`

## What the Installer Does

- Installs the required PXE packages and build tools
- Creates the PXE directory layout under `/opt/pxe`
- Records managed configuration and service states
- Generates and applies the Netplan bridge configuration
- Configures DHCPv4, DHCPv6, TFTP, radvd, and Apache
- Builds iPXE binaries for Legacy BIOS, x86_64 UEFI, and ARM64 UEFI
- Copies available EFI Shell, WinPE, and Ghost assets
- Generates the iPXE boot menu
- Creates ISO mount helpers and a systemd auto-mount service
- Supports reinstallation without overwriting the original-state snapshot
- Restores managed files and service states during uninstallation

Dependency packages and PXE logs are preserved after uninstallation.

## Repository Notes

Some boot assets are not stored in GitHub because of licensing or **NDA restrictions**. The repository may exclude:

- `.iso` and `.wim` images
- WinPE content
- Ghost files
- Other machine-specific boot assets

Missing optional assets are reported during installation and must be supplied manually if required.

The patch under `patch/v2.2_jetson_air021a1` is intended for PXE installer v2.2 and is not compatible with the v3.0.0 `/opt/pxe` layout without modification.

For the complete installation package, such as `pxe_installer_<VERSION>.tgz` or `pxe_installer_<VERSION>.run`, contact the author.

## Notes

- Ensure `ISO_PATH` exists and is readable before mounting ISO files.
- Ensure NetworkManager is installed and active before running the installer.
- Do not use the host's management interface as `PXE_INTERFACE` without reviewing the network impact.
- The PXE DHCP service should only be used on a trusted and isolated network.
- Update the hardcoded iPXE menu entries to match the available installation images.
- Verify the WinPE startup script and SMB path before using Windows deployment features.

If a script was saved with Windows CRLF line endings, convert it to LF:

```bash
sudo apt-get update
sudo apt-get install -y dos2unix
dos2unix pxe_installer.sh scripts/*.sh
```

## Reference

- [iPXE](https://ipxe.org/)
- [Add Drivers to an Offline Windows Image](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-and-remove-drivers-to-an-offline-windows-image?view=windows-11)