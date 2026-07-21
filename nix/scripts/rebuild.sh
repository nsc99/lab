#!/bin/bash

nix run nixpkgs#nixos-rebuild -- switch --flake .#${1} --target-host operator@${1}.lab --build-host operator@${1}.lab --sudo -L 