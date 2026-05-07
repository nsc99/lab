#!/bin/bash

nix run nixpkgs#nixos-rebuild -- switch --flake .#${1} --target-host opeartor@${1} --build-host operator@${1} --sudo -L 