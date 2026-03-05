#!/usr/bin/env bash
set -euo pipefail

install_dir="${HOME}/.grove"

echo "grove Uninstaller"
echo ""
echo "This will remove:"
echo "  • ${install_dir}/"
echo "  • ~/.local/bin/grove symlink (if exists)"
echo "  • PATH entry from shell config (if added)"
echo ""
echo "WARNING: All cloned repositories in ${install_dir}/clones/ will be deleted!"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Uninstall cancelled."
  exit 0
fi

# Remove symlink from ~/.local/bin if it exists
if [ -L "$HOME/.local/bin/grove" ]; then
  rm -f "$HOME/.local/bin/grove"
  echo "✓ Removed symlink from ~/.local/bin/grove"
fi

# Remove installation directory
if [ -d "$install_dir" ]; then
  echo "Removing ${install_dir}..."
  rm -rf "$install_dir"
  echo "✓ Removed installation directory"
else
  echo "⊘ Installation directory not found"
fi

# Remove PATH from shell config files
remove_path_from_file() {
  local file="$1"
  if [ -f "$file" ]; then
    if grep -q ".grove/bin" "$file" 2>/dev/null; then
      sed -i.bak '/# grove/d' "$file"
      sed -i.bak '/\.grove\/bin/d' "$file"
      sed -i.bak '/^$/N;/^\n$/d' "$file"
      rm -f "${file}.bak"
      echo "✓ Removed PATH from $file"
    fi
  fi
}

remove_path_from_file "${HOME}/.zshenv"
remove_path_from_file "${HOME}/.zshrc"
remove_path_from_file "${HOME}/.bash_profile"
remove_path_from_file "${HOME}/.bashrc"

echo ""
echo "✓ Uninstall complete!"
echo ""
echo "Reload your shell or run:"
echo "  source ~/.zshrc  # or ~/.bashrc"
