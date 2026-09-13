#!/bin/bash
# Reports whether this machine follows the multi-machine key convention:
# one key per machine, always at ~/.ssh/id_ed25519, declared on GitHub under
# both the Authentication and the Signing role.
#
# To run this script, run :
# /bin/bash -c "$(curl -fsSL https://kewin.dev/check)"
#
# Read-only. It never changes anything, and exits non-zero when something fails.

# No `set -e`: every check runs, and the summary at the end is the point.
set -uo pipefail

GITHUB_USERNAME=${GITHUB_USERNAME:-KewinDousse}
KEY=${KEY:-$HOME/.ssh/id_ed25519}
PUB="$KEY.pub"
SSH_CONFIG="$HOME/.ssh/config"

fails=0
warns=0
key_usable=0
key_body=""
GH_CODE=""
GH_BODY=""

if [ -t 1 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_OK=$(tput setaf 2); C_WARN=$(tput setaf 3); C_BAD=$(tput setaf 1)
  C_HEAD=$(tput bold);  C_OFF=$(tput sgr0)
else
  C_OK=""; C_WARN=""; C_BAD=""; C_HEAD=""; C_OFF=""
fi

section() { printf '\n%s%s%s\n' "$C_HEAD" "$1" "$C_OFF"; }
hint()    { printf '      → %s\n' "$1"; }
ok()      { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$1"; }

warn() {
  printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$1"
  warns=$((warns + 1))
  if [ $# -gt 1 ]; then hint "$2"; fi
}

bad() {
  printf '  %s✗%s %s\n' "$C_BAD" "$C_OFF" "$1"
  fails=$((fails + 1))
  if [ $# -gt 1 ]; then hint "$2"; fi
}

# -L: une clé atteinte par un lien symbolique reste une clé valable, et le mode
# propre du lien est toujours 777. BSD et GNU stat diffèrent sur le drapeau.
perms_of() {
  stat -L -c '%a' "$1" 2>/dev/null || stat -L -f '%Lp' "$1" 2>/dev/null
}

# L'empreinte seule.
fingerprint_of() {
  ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'
}

# `ssh-keygen -lf <privée>` préfère le .pub voisin quand il existe, donc comparer
# les deux directement serait circulaire: un .pub étranger se validerait lui-même.
# Un lien symbolique isolé force la lecture de la moitié publique stockée en clair
# dans le fichier privé, ce qui marche aussi sur une clé à passphrase.
fingerprint_of_private() {
  local src dir fp=""
  case "$1" in /*) src=$1 ;; *) src=$PWD/$1 ;; esac
  dir=$(mktemp -d) || return 1
  if ln -s "$src" "$dir/k" 2>/dev/null; then
    fp=$(fingerprint_of "$dir/k")
  fi
  rm -rf "$dir"
  printf '%s' "$fp"
}

# Un corps vide sur un 200 veut dire que le rôle est réellement vide, ce qui est
# un échec; un hôte injoignable veut seulement dire qu'on n'a pas pu savoir.
gh_fetch() {
  local out
  out=$(curl -sL --max-time 10 -w $'\n%{http_code}' "$1" 2>/dev/null) || return 1
  GH_CODE=${out##*$'\n'}
  GH_BODY=${out%$'\n'*}
}

# chezmoi vit souvent dans le préfixe brew, que le PATH d'un shell non
# interactif ne contient pas
chezmoi_bin() {
  command -v chezmoi 2>/dev/null && return 0
  [ -x /home/linuxbrew/.linuxbrew/bin/chezmoi ] && echo /home/linuxbrew/.linuxbrew/bin/chezmoi && return 0
  return 1
}

printf '%sConvention du trousseau — %s%s\n' "$C_HEAD" "$(hostname -s)" "$C_OFF"

# ============================================================
section "Clé d'identité"
# ============================================================

if [ -d "$KEY" ]; then
  bad "$KEY est un répertoire, pas une clé" \
      "Docker crée ça quand un bind-mount vise un chemin absent. rmdir, puis remets la clé."
elif [ ! -f "$KEY" ]; then
  bad "$KEY est absent" \
      "ssh-keygen -t ed25519 -f $KEY -C \"\$(hostname -s)\""
elif [ ! -f "$PUB" ]; then
  bad "$PUB est absent, la moitié publique manque" \
      "ssh-keygen -y -f $KEY > $PUB"
elif [ -z "$(fingerprint_of_private "$KEY")" ]; then
  bad "$KEY n'est pas une clé lisible" \
      "Fichier tronqué, ou dans un format que ce ssh-keygen ne connaît pas."
elif [ -z "$(fingerprint_of "$PUB")" ]; then
  bad "$PUB n'est pas une clé publique lisible" \
      "ssh-keygen -y -f $KEY > $PUB"
elif [ "$(fingerprint_of_private "$KEY")" != "$(fingerprint_of "$PUB")" ]; then
  bad "$PUB n'est pas la moitié publique de $KEY" \
      "Reliquat d'une rotation. Tout le reste vérifierait la mauvaise clé. ssh-keygen -y -f $KEY > $PUB"
else
  key_body=$(cut -d' ' -f2 "$PUB")
  if [ -z "$key_body" ]; then
    bad "$PUB est vide" "ssh-keygen -y -f $KEY > $PUB"
  else
    key_usable=1
    ok "$KEY et sa moitié publique concordent"
  fi
fi

if [ "$key_usable" -eq 1 ]; then
  if ssh-keygen -lf "$PUB" 2>/dev/null | grep -q 'ED25519'; then
    ok "type ed25519"
  else
    bad "la clé n'est pas une ed25519" "La convention veut une ed25519."
  fi

  perms=$(perms_of "$KEY")
  if [ -n "$perms" ] && [ "$((8#$perms & 8#077))" -eq 0 ]; then
    ok "permissions $perms, rien pour le groupe ni pour les autres"
  else
    bad "permissions ${perms:-?} sur la clé privée" "chmod 600 $KEY"
  fi

  # Le fichier est déjà prouvé lisible, donc un échec ici ne peut plus venir que
  # d'une passphrase, et pas d'une clé corrompue
  if ssh-keygen -y -P "" -f "$KEY" >/dev/null 2>&1; then
    bad "la clé n'a pas de passphrase" "ssh-keygen -p -f $KEY"
  else
    ok "protégée par une passphrase"
  fi
fi

if [ -e "$HOME/.ssh/id_ed25519_git" ]; then
  warn "$HOME/.ssh/id_ed25519_git traîne encore" \
       "Nom d'avant la convention. Vérifie que plus rien ne le vise, puis supprime-le."
fi

# ============================================================
section "Déclaration sur GitHub ($GITHUB_USERNAME)"
# ============================================================

if [ "$key_usable" -eq 0 ]; then
  warn "rôles non vérifiés, il n'y a pas de clé publique fiable à chercher"
else
  if ! gh_fetch "https://github.com/$GITHUB_USERNAME.keys"; then
    warn "GitHub injoignable, rôle Authentication non vérifié"
  elif [ "$GH_CODE" != "200" ]; then
    bad "GitHub répond $GH_CODE sur les clés de $GITHUB_USERNAME" "Nom de compte correct ?"
  elif printf '%s' "$GH_BODY" | grep -qF "$key_body"; then
    ok "rôle Authentication déclaré"
  else
    bad "rôle Authentication absent" \
        "Sans lui, les autres machines ne reconnaissent pas cette clé comme signataire."
  fi

  if ! gh_fetch "https://api.github.com/users/$GITHUB_USERNAME/ssh_signing_keys"; then
    warn "GitHub injoignable, rôle Signing non vérifié"
  elif [ "$GH_CODE" != "200" ]; then
    bad "l'API GitHub répond $GH_CODE sur les clés de signature" "Nom de compte correct ?"
  elif printf '%s' "$GH_BODY" | grep -qF "$key_body"; then
    ok "rôle Signing déclaré"
  else
    bad "rôle Signing absent" \
        "Les commits de cette machine sortiront Unverified sur github.com. https://github.com/settings/keys"
  fi

  # -i et IdentitiesOnly: sinon une autre clé de l'agent peut répondre à la
  # place, et le test certifierait une clé qu'il n'a pas testée
  gh_says=$(ssh -T -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o ConnectTimeout=10 git@github.com 2>&1)
  case "$gh_says" in
    *"Hi $GITHUB_USERNAME!"*) ok "GitHub authentifie cette clé comme $GITHUB_USERNAME" ;;
    *"Hi "*)                  bad "GitHub authentifie un autre compte: $gh_says" ;;
    *)                        warn "pas d'authentification GitHub testable" \
                                   "Agent verrouillé ou hors ligne. ssh-add $KEY" ;;
  esac
fi

# ============================================================
section "Signature git"
# ============================================================

# --global partout: le script se lance de n'importe où, et une surcharge locale
# de dépôt ne dit rien de la configuration de la machine
git_global() { git config --global --get "$@" 2>/dev/null; }

configured=$(git_global user.signingkey)
configured_expanded=${configured/#\~/$HOME}
if [ -z "$configured" ]; then
  bad "user.signingKey n'est pas configuré"
elif [ "$configured_expanded" = "$PUB" ] || [ "$configured_expanded" = "$KEY" ]; then
  ok "user.signingKey vise $configured"
else
  bad "user.signingKey vise $configured" "Attendu: $PUB"
fi

fmt=$(git_global gpg.format)
if [ "$fmt" = "ssh" ]; then
  ok "gpg.format = ssh"
else
  bad "gpg.format = ${fmt:-<vide>}" "Attendu: ssh"
fi

for setting in commit.gpgsign tag.gpgsign; do
  # --type=bool: git accepte aussi 1, yes et on, qui veulent tous dire true
  actual=$(git_global --type=bool "$setting")
  if [ "$actual" = "true" ]; then
    ok "$setting = true"
  else
    bad "$setting = ${actual:-<vide>}" "Attendu: true"
  fi
done

signers_file=$(git_global gpg.ssh.allowedsignersfile)
signers_expanded=${signers_file/#\~/$HOME}
if [ -z "$signers_file" ]; then
  bad "gpg.ssh.allowedSignersFile n'est pas configuré" \
      "Sans lui, rien n'est vérifiable localement et git log sort des ?"
elif [ ! -f "$signers_expanded" ]; then
  bad "$signers_file est déclaré mais absent"
else
  ok "allowedSignersFile pointe sur un fichier existant"
  if [ "$key_usable" -eq 1 ]; then
    if grep -qF "$key_body" "$signers_expanded"; then
      ok "cette machine figure dans allowed_signers"
    else
      bad "cette machine n'est pas dans allowed_signers" \
          "Ses propres commits sortiront en U. Déclare la clé en Authentication sur GitHub, puis chezmoi apply."
    fi
  fi
fi

# ============================================================
section "Config SSH"
# ============================================================

if [ -f "$SSH_CONFIG" ]; then
  perms=$(perms_of "$SSH_CONFIG")
  if [ -n "$perms" ] && [ "$((8#$perms & 8#077))" -eq 0 ]; then
    ok "$SSH_CONFIG en $perms"
  else
    warn "$SSH_CONFIG en ${perms:-?}" "chmod 600 $SSH_CONFIG"
  fi

  # ssh peut proposer plusieurs identités: ce qui compte est que la nôtre en soit
  offered=$(ssh -G github.com 2>/dev/null | awk '/^identityfile /{print $2}')
  found=0
  while IFS= read -r line; do
    if [ -n "$line" ] && [ "${line/#\~/$HOME}" = "$KEY" ]; then found=1; fi
  done <<< "$offered"
  if [ "$found" -eq 1 ]; then
    ok "github.com propose $KEY"
  else
    bad "github.com ne propose pas $KEY" "Proposé: $(printf '%s' "$offered" | tr '\n' ' ')"
  fi
else
  bad "$SSH_CONFIG est absent" "chezmoi apply --init le pose."
fi

# ssh-add distingue trois cas par son code de sortie: 0 des clés, 1 agent vide,
# 2 aucun agent joignable
ssh-add -l >/dev/null 2>&1
agent_status=$?
if [ "$agent_status" -eq 0 ]; then
  ok "un agent SSH est joignable et porte au moins une clé"
elif [ "$agent_status" -eq 1 ]; then
  warn "agent SSH joignable mais vide" "ssh-add $KEY"
else
  warn "aucun agent SSH joignable" "Ouvre un nouveau shell, le .zshrc en démarre un."
fi

# ============================================================
section "Dotfiles"
# ============================================================

if cm=$(chezmoi_bin); then
  ok "chezmoi installé"

  if src=$("$cm" source-path 2>/dev/null) && [ -d "$src" ]; then
    remote=$(git -C "$src" remote get-url origin 2>/dev/null)
    case "$remote" in
      *"$GITHUB_USERNAME"*) ok "la source vise $remote" ;;
      "")                   warn "la source n'a pas de remote origin" ;;
      *)                    bad "la source vise $remote" \
                                "git -C \"\$(chezmoi source-path)\" remote set-url origin git@github.com:$GITHUB_USERNAME/dotfiles.git" ;;
    esac
  fi

  # stderr écarté: un avertissement chezmoi n'est pas une divergence à appliquer
  if status=$("$cm" status 2>/dev/null); then
    if [ -z "$status" ]; then
      ok "aucune divergence à appliquer"
    else
      warn "$(printf '%s\n' "$status" | grep -c '') entrée(s) divergentes" "chezmoi apply --init"
    fi
  else
    bad "chezmoi status a échoué" "$("$cm" status 2>&1 | head -1)"
  fi

  # execute-template plutôt que `data`, qui répète les clés sous chezmoi.config
  profile=$("$cm" execute-template \
    '{{ printf "work=%v wsl=%v headless=%v" .work .wsl .headless }}' 2>/dev/null)
  if [ -n "$profile" ]; then printf '      profil déduit: %s\n' "$profile"; fi
else
  bad "chezmoi n'est pas installé" "brew install chezmoi"
fi

# ============================================================

printf '\n'
if [ "$fails" -eq 0 ] && [ "$warns" -eq 0 ]; then
  printf '%sAux normes.%s\n' "$C_OK" "$C_OFF"
  exit 0
fi
printf '%s%d problème(s)%s, %s%d avertissement(s)%s.\n' \
  "$C_BAD" "$fails" "$C_OFF" "$C_WARN" "$warns" "$C_OFF"
[ "$fails" -eq 0 ] && exit 0
exit 1
