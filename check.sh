#!/bin/bash
# Reports whether this machine follows the multi-machine key convention:
# one key per machine, always at ~/.ssh/id_ed25519, declared on GitHub under
# both the Authentication and the Signing role.
#
# To run this script, run :
# /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KewinDousse/utils/master/check.sh)"
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

# BSD and GNU stat disagree on the flag for the permission bits
perms_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# chezmoi usually lives in the brew prefix, which a non-interactive shell misses
chezmoi_bin() {
  command -v chezmoi 2>/dev/null && return 0
  [ -x /home/linuxbrew/.linuxbrew/bin/chezmoi ] && echo /home/linuxbrew/.linuxbrew/bin/chezmoi && return 0
  return 1
}

printf '%sConvention du trousseau — %s%s\n' "$C_HEAD" "$(hostname -s)" "$C_OFF"

# ============================================================
section "Clé d'identité"
# ============================================================

key_usable=0

if [ -d "$KEY" ]; then
  bad "$KEY est un répertoire, pas une clé" \
      "Docker crée ça quand un bind-mount vise un chemin absent. rmdir, puis remets la clé."
elif [ ! -f "$KEY" ]; then
  bad "$KEY est absent" \
      "ssh-keygen -t ed25519 -f $KEY -C \"\$(hostname -s)\""
elif [ ! -f "$PUB" ]; then
  bad "$PUB est absent, la clé publique manque" \
      "ssh-keygen -y -f $KEY > $PUB"
else
  key_usable=1
  ok "$KEY est bien un fichier"

  if ssh-keygen -lf "$PUB" 2>/dev/null | grep -q 'ED25519'; then
    ok "type ed25519"
  else
    bad "la clé n'est pas une ed25519" "La convention veut une ed25519."
  fi

  perms=$(perms_of "$KEY")
  if [ "$perms" = "600" ]; then
    ok "permissions 600 sur la clé privée"
  else
    bad "permissions $perms sur la clé privée" "chmod 600 $KEY"
  fi

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
  warn "rôles non vérifiés, il n'y a pas de clé publique à chercher"
else
  # Le corps base64 seul: le commentaire diffère entre le fichier local et GitHub
  key_body=$(cut -d' ' -f2 "$PUB")

  auth_keys=$(curl -fsSL --max-time 10 "https://github.com/$GITHUB_USERNAME.keys" 2>/dev/null)
  if [ -z "$auth_keys" ]; then
    warn "GitHub injoignable, rôle Authentication non vérifié"
  elif printf '%s' "$auth_keys" | grep -qF "$key_body"; then
    ok "rôle Authentication déclaré"
  else
    bad "rôle Authentication absent" \
        "Sans lui, les autres machines ne reconnaissent pas cette clé comme signataire."
  fi

  sign_keys=$(curl -fsSL --max-time 10 \
    "https://api.github.com/users/$GITHUB_USERNAME/ssh_signing_keys" 2>/dev/null)
  if [ -z "$sign_keys" ]; then
    warn "GitHub injoignable, rôle Signing non vérifié"
  elif printf '%s' "$sign_keys" | grep -qF "$key_body"; then
    ok "rôle Signing déclaré"
  else
    bad "rôle Signing absent" \
        "Les commits de cette machine sortiront Unverified sur github.com. https://github.com/settings/keys"
  fi

  gh_says=$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 git@github.com 2>&1)
  case "$gh_says" in
    *"Hi $GITHUB_USERNAME!"*) ok "GitHub authentifie bien cette machine" ;;
    *"Hi "*)                  bad "GitHub authentifie un autre compte: $gh_says" ;;
    *)                        warn "pas d'authentification GitHub testable" \
                                   "Agent verrouillé ou hors ligne. ssh-add $KEY" ;;
  esac
fi

# ============================================================
section "Signature git"
# ============================================================

expected_pub="$PUB"
configured=$(git config --get user.signingkey 2>/dev/null)
configured_expanded=${configured/#\~/$HOME}
if [ -z "$configured" ]; then
  bad "user.signingKey n'est pas configuré"
elif [ "$configured_expanded" = "$expected_pub" ]; then
  ok "user.signingKey vise $configured"
else
  bad "user.signingKey vise $configured" "Attendu: $expected_pub"
fi

for pair in "gpg.format=ssh" "commit.gpgsign=true" "tag.gpgsign=true"; do
  setting=${pair%%=*}
  expected=${pair#*=}
  actual=$(git config --get "$setting" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    ok "$setting = $expected"
  else
    bad "$setting = ${actual:-<vide>}" "Attendu: $expected"
  fi
done

signers_file=$(git config --get gpg.ssh.allowedsignersfile 2>/dev/null)
signers_expanded=${signers_file/#\~/$HOME}
if [ -z "$signers_file" ]; then
  bad "gpg.ssh.allowedSignersFile n'est pas configuré" \
      "Sans lui, rien n'est vérifiable localement et git log sort des ?"
elif [ ! -f "$signers_expanded" ]; then
  bad "$signers_file est déclaré mais absent"
else
  ok "allowedSignersFile pointe sur un fichier existant"
  if [ "$key_usable" -eq 1 ]; then
    if grep -qF "$(cut -d' ' -f2 "$PUB")" "$signers_expanded"; then
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
  if [ "$perms" = "600" ]; then
    ok "$SSH_CONFIG en 600"
  else
    warn "$SSH_CONFIG en $perms" "chmod 600 $SSH_CONFIG"
  fi

  resolved=$(ssh -G github.com 2>/dev/null | awk '/^identityfile /{print $2; exit}')
  resolved_expanded=${resolved/#\~/$HOME}
  if [ "$resolved_expanded" = "$KEY" ]; then
    ok "github.com utilise $resolved"
  else
    bad "github.com utilise ${resolved:-<rien>}" "Attendu: $KEY"
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

  status=$("$cm" status 2>&1)
  if [ -z "$status" ]; then
    ok "aucune divergence à appliquer"
  else
    warn "$(printf '%s' "$status" | wc -l) entrée(s) divergentes" "chezmoi apply --init"
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
