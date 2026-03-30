#!/bin/sh
# cSpell:ignore awww
awww query \
    | awk -F'[: ]+' '/currently displaying/{print $NF}'
