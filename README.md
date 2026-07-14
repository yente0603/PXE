# PXE

**Latest Version**: 2.2  
**Release Date**: 2026/05/21  
**Author**: Jasper Lee  

This project provides a repeatable PXE server setup for Ubuntu Desktop. It automates the network boot environment, including bridge networking, DHCP, TFTP, HTTP, and iPXE configuration for both IPv4 and IPv6.

## Features

- IPv4 and IPv6 PXE boot support
- Automated setup script by one click
- Supports bootup x86_64 and aarch64 systems (through patch)
- Optional local assets for EFI Shell, WinPE, and Ghost integration

## Compatibility

- Verified on Ubuntu Desktop 24.04.3
- Assumes a desktop installation with NetworkManager enabled
- Uses netplan with the NetworkManager renderer for bridge setup
- Requires `sudo` because the installer modifies networking and system services

If you run a server-only or heavily customized Ubuntu install, review the script and configuration before use.

## How to Run

1. Copy the sample configuration:

   ```bash
   cp config.env.example config.env
   ```

2. Edit `config.env` and make sure the required values are correct:
   - `PXE_INTERFACE` for the physical network interface
   - `PXE_BRIDGE` for the bridge name
   - IPv4 and IPv6 addresses and DHCP ranges
   - `ISO_PATH` pointing to a mounted installation image directory

3. Run the installer with `sudo`:

   ```bash
   sudo bash pxe_installer.sh
   ```

4. (Optional) Edit your configuration:
   - Edit the iPXE menu in `/pxe/tftp/ipxe/boot.ipxe` to match your images
   - Edit Samba information in `/pxe/http/winpe/startup.bat` for the WinPE environment
   - Use `sudo bash pxe_installer.sh -h` to view all supported options

## What the Installer Does

- Installs the required PXE-related packages and tools
- Creates the local service directories under `/pxe`
- Generates and applies the Netplan bridge configuration
- Configures DHCPv4 and DHCPv6 services
- Sets up TFTP and Apache HTTP serving for boot files and installation media
- Copies local boot assets when they are available, including iPXE, EFI shell files, and WinPE files
- Builds the PXE boot menu for `x86_64` and `aarch64`
- Supports install, mount-only, unmount-only, uninstall, and `--no-ipxe-build` workflows

## Repository Notes

Some boot assets are not stored in GitHub because they are covered by **NDA restrictions**. The installer expects some files to exist locally and the repository `.gitignore` intentionally excludes items such as:

- `*.iso`
- `*.wim`
- Ghost
- WinPE content under `assets/winpe/`
- Other generated or machine-specific assets used by the installer

The script checks for these files at runtime and only installs the corresponding PXE menu entries or services when the local files are present. In practice, this means you may need to prepare ISO, WIM, WinPE, EFI Shell, and Ghost files on your machine before running the installer. If you need the full installation package such as `pxe_installer_<VERSION>.tgz`, please contact the author.

## Notes

- Make sure `ISO_PATH` is mounted and readable before running the script.
- If you are on a minimal or server-oriented Ubuntu image, confirm that NetworkManager is installed and active before running the installer.
- The installer modifies system networking and service configuration, so it should only be used in a trusted internal network.
- If you encounter the CRLF issue such as `sudo: unable to execute ./pxe_installer_<VERSION>.sh: No such file or directory`, please refer commands below to convert the script in LF:

    ```bash
    sudo apt update
    sudo apt install dos2unix
    dos2unix ./pxe_installer_<VERSION>.sh
    ```

- If you are customizing Windows boot support, verify `/pxe/http/winpe/startup.bat` and the corresponding SMB path before enabling WinPE in the menu.

## Reference

- [iPXE](https://ipxe.org/)
- [Add driver to an offline Windows image](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/add-and-remove-drivers-to-an-offline-windows-image?view=windows-11)
