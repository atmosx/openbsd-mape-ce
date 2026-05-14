#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
prove -v tests/*.t
