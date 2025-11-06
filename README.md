# Raspberry Pi 5 VM Host Setup Script

This repository contains [`setup_vmhost_pi5.sh`](setup_vmhost_pi5.sh), a guided Bash script that prepares a Raspberry Pi 5 to run virtual machines via KVM and libvirt.

## What the script does

When executed, the script performs the following tasks:

- Confirms that the system is running on 64‑bit ARM (`aarch64`) hardware with KVM support.
- Ensures the required kernel modules (`kvm` and `kvm_arm64`) are available.
- Installs and enables the packages needed for virtualization (QEMU, libvirt, virt-manager, bridge-utils, etc.).
- Adds your chosen non-root user to the `kvm` and `libvirt` groups so they can manage VMs.
- Sets up the default libvirt NAT network and optionally defines a bridged network using `br0`.
- Optionally creates an example Ubuntu 22.04 ARM64 VM using `virt-install`.
- Summarizes the changes at the end and reminds you to re-login so new group memberships take effect.

## Requirements

- Raspberry Pi 5 running Raspberry Pi OS (Debian-based) in 64-bit mode (`aarch64`).
- Internet access for package installation and (optionally) downloading the Ubuntu ISO image.
- An existing non-root user account that will manage the virtual machines.

## Usage

1. Download the repository or copy the script to your Raspberry Pi 5.
2. Make the script executable (if necessary):
   ```bash
   chmod +x setup_vmhost_pi5.sh
   ```
3. Run the script. It will automatically elevate to `sudo` if not run as root:
   ```bash
   ./setup_vmhost_pi5.sh
   ```
4. Follow the on-screen prompts to confirm package installations, configure networking options, and decide whether to create an example VM.

## After running the script

- Log out and back in as the user that will manage VMs so the new group memberships apply.
- Launch the graphical management interface with:
  ```bash
  virt-manager
  ```
- Use `virsh` for command-line management, for example:
  ```bash
  virsh list --all
  virsh start <vm-name>
  virsh shutdown <vm-name>
  ```

## Notes

- If you enable the optional bridge configuration, you may need to reboot or restart networking for the bridge to come online.
- The script is designed to be idempotent: you can re-run it to confirm the environment or pick up missing packages.

