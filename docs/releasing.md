# Releases

English | [日本語](releasing.ja.md)

A `vX.Y.Z` tag on `main` publishes a release. `.github/workflows/release.yml` builds the app for
Apple silicon and Intel, attaches `notepanel-X.Y.Z.zip` to a GitHub release, and pushes
`Casks/notepanel.rb` to [kkensuke/homebrew-tap](https://github.com/kkensuke/homebrew-tap). The tag
must match `version` in `scripts/bundle.sh`, so set that on `main` first, then:

```sh
git tag -s vX.Y.Z -m "notepanel X.Y.Z"
git push origin vX.Y.Z
```

`ARCHS="arm64 x86_64" scripts/bundle.sh` builds the same universal app locally. The workflow pushes
to the tap with the secret `HOMEBREW_TAP_TOKEN` of the GitHub environment `release`: a
fine-grained token with read and write access to the contents of `homebrew-tap` only.
