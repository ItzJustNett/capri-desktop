#!/usr/bin/env bash
# Встановлює/оновлює Capri у NixOS-конфіг /etc/nixos (той самий шаблон, що й ramoon).
#   sudo ./install-nixos.sh            # конфіг xoperr (GNOME)
#   sudo ./install-nixos.sh xoperr-ii  # інший nixosConfiguration
#   ./install-nixos.sh --dry-run       # лише показати diff flake.nix, нічого не змінювати
# Повторний запуск = оновлення: копіює свіжий код, оновлює lock, перебудовує.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIXOS=/etc/nixos
DEST="$NIXOS/flakes/capri"
HOST="xoperr"
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    *) HOST="$a" ;;
  esac
done

patch_flake() {
  # 1) input після блоку ramoon; 2) аргумент outputs; 3) модуль у baseModules
  awk '
    /^    capri = \{/ { has_input = 1 }
    { print }
    /^    ramoon = \{/ { in_ramoon = 1 }
    in_ramoon && /^    \};/ {
      in_ramoon = 0
      if (!has_input) {
        print ""
        print "    capri = {"
        print "      url = \"path:./flakes/capri\";"
        print "      inputs.nixpkgs.follows = \"nixpkgs\";"
        print "    };"
      }
    }
    /^      ramoon,$/ && !done_arg { print "      capri,"; done_arg = 1 }
    /^        ramoon\.nixosModules\.default$/ && !done_mod { print "        capri.nixosModules.default"; done_mod = 1 }
  ' "$1"
}

if grep -q 'flakes/capri' "$NIXOS/flake.nix"; then
  PATCHED="$(cat "$NIXOS/flake.nix")"
else
  PATCHED="$(patch_flake "$NIXOS/flake.nix")"
  for want in 'path:./flakes/capri' '      capri,' 'capri.nixosModules.default'; do
    grep -qF -- "$want" <<<"$PATCHED" || { echo "Не вдалося вписати «$want» у flake.nix — структура змінилась, додай вручну." >&2; exit 1; }
  done
fi

if [ "$DRY" = 1 ]; then
  diff -u "$NIXOS/flake.nix" <(printf '%s\n' "$PATCHED") || true
  exit 0
fi

[ "$(id -u)" = 0 ] || { echo "Запусти через sudo: sudo $0 $*" >&2; exit 1; }
USER_NAME="${SUDO_USER:-xoperr}"

echo "→ Копіюю код у $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
( cd "$SRC" && tar --exclude=./node_modules --exclude=./result --exclude=./captures --exclude=./.git -cf - . ) | tar -C "$DEST" -xf -
chown -R root:root "$DEST"

if ! grep -q 'flakes/capri' "$NIXOS/flake.nix"; then
  echo "→ Вписую capri у flake.nix (бекап: flake.nix.bak-capri)"
  cp "$NIXOS/flake.nix" "$NIXOS/flake.nix.bak-capri"
  printf '%s\n' "$PATCHED" >"$NIXOS/flake.nix"
fi

# /etc/nixos — git-репозиторій: флейк не бачить файлів, яких немає в індексі
if git -C "$NIXOS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$NIXOS" add flake.nix flakes/capri
fi

echo "→ Оновлюю lock для capri"
nix --extra-experimental-features 'nix-command flakes' flake update capri --flake "$NIXOS"

echo "→ nixos-rebuild switch --flake $NIXOS#$HOST"
nixos-rebuild switch --flake "$NIXOS#$HOST"

echo "→ Зупиняю тестову копію і запускаю Capri як сервіс у сесії $USER_NAME"
pkill -u "$USER_NAME" -f "[e]lectron-unwrapped.*capri" 2>/dev/null || true
systemctl --user -M "$USER_NAME@" daemon-reload || true
systemctl --user -M "$USER_NAME@" restart capri.service || echo "  (стартує автоматично при наступному вході)"

echo "Готово. Capri стартуватиме з кожним входом у сесію; Ctrl+Alt+C — сховати/показати."
