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
  description = "Host:port of a local nix-serve for faster builds (e.g. 192.168.67.1:5000)"
}

source "tart-cli" "vanilla-nix" {
  vm_base_name = var.base_image
  vm_name      = "macos-vanilla-nix"
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
      "NIX_SERVE_HOST=${var.nix_serve_host}",
    ]
  }

  provisioner "shell" {
    script = "scripts/install-nix-darwin.sh"
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
