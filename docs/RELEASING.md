# Releasing Dash

Dash updates itself from the GitHub releases of this repository. A release is a tag
`v<version>` with a `Dash-<version>.zip` attached; the app finds it, installs it and relaunches.

## Publish a release

From the repository root, with your changes pushed to `main`:

```sh
scripts/release.sh 0.2.4
gh release create v0.2.4 dist/Dash-0.2.4.zip --title "Dash 0.2.4" --target main --generate-notes
```

1. `scripts/release.sh <version>` builds a Release `Dash.app` at that version (the build number is
   the commit count), checks its signature and zips it as `dist/Dash-<version>.zip`.
2. `gh release create` tags `main` as `v<version>` on GitHub and uploads the zip.
   `--generate-notes` writes the notes from the commits, without opening an editor.

Pick a version higher than the installed one: the app only offers a newer version, comparing the
numbers part by part (`0.10.0` is newer than `0.9.3`).

To also install the build on this Mac right away, add `--install`:

```sh
scripts/release.sh 0.2.4 --install    # quits Dash, replaces /Applications/Dash.app, opens it
```

## What the app does

Settings › Updates shows the installed version and the latest release. Dash checks at launch and
every six hours (**Check automatically**), or on **Check Now** and **Dash › Check for Updates…**.
When a newer release exists, **Install … and Relaunch** (also in the menu bar item):

1. downloads the zip, and checks it against GitHub's SHA-256 when GitHub gives one;
2. unzips it and checks it is Dash (same bundle identifier), at that version, with a valid code
   signature;
3. quits; a small script waits for Dash to exit, swaps the app bundle in place (the old one comes
   back if the swap fails) and opens the new one.

Debug builds check for releases but never replace themselves: install a Release build first.

## Sources

**Source** in Settings › Updates says where releases come from:

| Source | Example | Releases |
|---|---|---|
| A GitHub repository | `sessaidi/dash`, a GitHub URL, or `git@github.com:sessaidi/dash.git` | The latest release and its `Dash-*.zip` |
| A local folder | a Dash checkout | The newest `Dash-<version>.zip` in the folder or its `dist/` |

The default is the repository in `DashUpdateRepository` (`Config/Dash-Info.plist`). With a local
checkout as the source, `scripts/release.sh <version>` is enough: no GitHub release needed.

Private repositories use the GitHub CLI's login (`gh auth login`).

## When it doesn't work

| Settings › Updates says | Why | Fix |
|---|---|---|
| … has no published release yet | The repository exists but has no release | Publish one (above) |
| … wasn't found | Wrong name, or a private repository without a `gh` login | Check **Source**, run `gh auth login` |
| Release … has no Dash-….zip | The release has no zip attached | `gh release upload v<version> dist/Dash-<version>.zip` |
| The zip holds another version of Dash | The zip was built with another version than the tag | Rebuild with the tag's version and upload it again (`--clobber`) |
| Dash can't write to /Applications | The folder isn't writable for your user | Install by hand once: `scripts/release.sh <version> --install` |
| Debug builds don't install updates | Running from Xcode or the build folder | Use the app in `/Applications` |

The app is signed ad hoc, not with a Developer ID: the signature check proves the bundle is intact,
not who built it, so only point **Source** at repositories and folders you trust.
