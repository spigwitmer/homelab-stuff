#!/bin/sh

_venv/bin/ansible-playbook -i inventory.yaml -K headscale.yaml
