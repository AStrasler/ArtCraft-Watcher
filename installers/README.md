# Installer layer

This directory contains **code only** while ArtCraft Watcher remains public. Do not commit MSI binaries or generated manifests to this repository.

Run locally with Python 3.11+:

```powershell
python installers/sync.py --directory "D:\\PrivateArtCraftInstallers"
```

The command retrieves official `storytold` release assets for all seven applications, checks each MSI against the publisher's SHA256SUMS.txt and GitHub's asset digest when available, and replaces the local installer only after verification. Stable filenames ensure exactly one current MSI per app in the chosen destination. A local manifest records provenance and versions.

The command stops on a failed verification without replacing that application's existing MSI. It does not install software or upload files to GitHub. Use a **private** destination; no GitHub repository is currently configured for binary uploads. Git history is not bounded merely by replacing files; Git LFS or history management is required before implementing a private GitHub folder archive.
