# 🛠️ Scripts personnels

Collection de scripts shell pour automatiser diverses tâches (installation système, configuration, maintenance…).

## Structure du dépôt

```
scripts/        → tous les scripts shell
update_readme.sh → script de mise à jour automatique du README
.github/workflows/update-readme.yml → workflow GitHub Actions
```

## 🔄 Mise à jour automatique du README

Le fichier `README.md` est mis à jour automatiquement via GitHub Actions à chaque push sur `main` lorsqu'un script est ajouté ou modifié dans le dossier `scripts/`.

Pour mettre à jour le README localement :

```bash
./update_readme.sh
```

<!-- SCRIPTS_START -->

## 📂 Scripts disponibles

### `install_arch.sh`

> install_arch.sh — Installation automatisée Arch Linux + dots-hyprland

Ce script :
  1. Installe Arch via archinstall avec les configs fournies
  2. Installe yay (AUR helper)
  3. Installe le thème dots-hyprland (illogical-impulse)
  4. Configure arch-update
  5. Désactive SDDM → TTY-only login + Hyprland auto-start
  6. Corrige son/micro, power management, clés SSH, etc.
  7. Applique des workarounds conditionnels pour les bugs connus

**Usage :**
```bash
  Depuis l'ISO Arch Linux live :
    curl -LO https://raw.githubusercontent.com/isoura4/scripts/main/scripts/install_arch.sh
    chmod +x install_arch.sh
    ./install_arch.sh                  # Installation complète
    ./install_arch.sh --phase 2        # Reprendre depuis la phase 2
    ./install_arch.sh --phase 3        # Reprendre depuis la phase 3
```

---

<!-- SCRIPTS_END -->
