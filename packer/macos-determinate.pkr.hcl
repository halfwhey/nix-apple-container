packer {
  required_plugins {
    tart = {
      version = ">= 1.14.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "base_image" {
  type    = string
  default = "ghcr.io/cirruslabs/macos-sequoia-base:latest"
}

variable "nix_serve_host" {
  type        = string
  default     = ""
  description = "Host:port of a local nix-serve for faster builds"
}

variable "nix_determinate_version" {
  type        = string
  default     = "3.17.1"
  description = "Determinate Nix version (maps to nix-installer GitHub release)"
}

variable "nixpkgs_rev" {
  type        = string
  default     = "e80236013dc8b77aa49ca90e7a12d86f5d8d64c9"
  description = "nixpkgs commit to pin in the VM's nix-darwin config"
}

variable "nix_darwin_rev" {
  type        = string
  default     = "da529ac9e46f25ed5616fd634079a5f3c579135f"
  description = "nix-darwin commit to pin in the VM's nix-darwin config"
}


locals {
  nix_installer_url = "https://github.com/DeterminateSystems/nix-installer/releases/download/v${var.nix_determinate_version}/nix-installer.sh"
  image_tag         = "nix-darwin-${substr(var.nix_darwin_rev, 0, 7)}-nixpkgs-${substr(var.nixpkgs_rev, 0, 7)}-determinate-${var.nix_determinate_version}"
}

source "tart-cli" "determinate" {
  vm_base_name = var.base_image
  vm_name      = local.image_tag
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 50
  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "120s"
}

build {
  sources = ["source.tart-cli.determinate"]

  provisioner "shell" {
    script = "scripts/install-determinate-nix.sh"
    environment_vars = [
      "NIX_INSTALLER_URL=${local.nix_installer_url}",
      "NIX_SERVE_HOST=${var.nix_serve_host}",
    ]
  }

  provisioner "shell" {
    script = "scripts/install-nix-darwin.sh"
    environment_vars = [
      "NIXPKGS_REV=${var.nixpkgs_rev}",
      "NIX_DARWIN_REV=${var.nix_darwin_rev}",
      "NIX_SERVE_HOST=${var.nix_serve_host}",
    ]
  }

  # Shrink the image before saving
  provisioner "shell" {
    inline = [
      "export PATH=/run/current-system/sw/bin:/usr/local/bin:/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH",
      "sudo rm -rf /Library/Caches/*",
      "rm -rf ~/Library/Caches/*",
      "nix store gc",
    ]
  }
}
