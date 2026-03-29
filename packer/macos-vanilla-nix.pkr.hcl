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

variable "nix_version" {
  type        = string
  default     = "2.33.3"
  description = "Nix version to install"
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
  image_tag = "nix-darwin-vanilla-${var.nix_version}-${substr(var.nixpkgs_rev, 0, 7)}-${substr(var.nix_darwin_rev, 0, 7)}"
}

source "tart-cli" "vanilla-nix" {
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
  sources = ["source.tart-cli.vanilla-nix"]

  provisioner "shell" {
    script = "scripts/install-vanilla-nix.sh"
    environment_vars = [
      "NIX_VERSION=${var.nix_version}",
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
