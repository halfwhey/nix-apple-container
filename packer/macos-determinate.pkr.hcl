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

source "tart-cli" "determinate" {
  vm_base_name = var.base_image
  vm_name      = "macos-determinate"
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
  }

  provisioner "shell" {
    script = "scripts/install-nix-darwin.sh"
  }

  # Shrink the image before pushing
  provisioner "shell" {
    inline = [
      "sudo rm -rf /Library/Caches/*",
      "sudo rm -rf ~/Library/Caches/*",
      "nix store gc",
    ]
  }
}
