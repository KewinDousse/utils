Write-Output "Installing Chrome and Firefox..."
winget install Google.Chrome
winget install Mozilla.Firefox

Write-Output "Installing VSCode ..."
winget install Microsoft.VisualStudioCode

Write-Output "Installing 7zip, VLC and PowerToys..."
winget install 7zip.7zip
winget install VideoLAN.VLC
winget install Microsoft.PowerToys

Write-Output "Installing Discord and Spotify..."
winget install Discord.Discord
winget install Spotify.Spotify

Write-Output "Installing Git..."
winget install Git.Git

Write-Output "Installing YubiKey Manager CLI..."
winget install --exact --id Yubico.YubiKeyManagerCLI

Write-Output "Installing Winaero Tweaker..."
winget install -e --id winaero.tweaker

Write-Output "Done"
pause
