# リリース

[English](releasing.md) | 日本語

`main` 上のコミットに `vX.Y.Z` のタグを付けると、リリースを公開する。`.github/workflows/release.yml` が、Apple シリコンと Intel の両方で動くアプリをビルドし、`notepanel-X.Y.Z.zip` を GitHub のリリースに添付し、`Casks/notepanel.rb` を [kkensuke/homebrew-tap](https://github.com/kkensuke/homebrew-tap) に push する。タグは `scripts/bundle.sh` の `version` と一致していなければならない。先に `main` でこの値を変えてから、次を実行する。

```sh
git tag -s vX.Y.Z -m "notepanel X.Y.Z"
git push origin vX.Y.Z
```

`ARCHS="arm64 x86_64" scripts/bundle.sh` で、同じユニバーサルアプリを手元でもビルドできる。ワークフローは、GitHub の environment `release` にある secret `HOMEBREW_TAP_TOKEN` を使って tap に push する。この secret には、`homebrew-tap` の contents だけを読み書きできる fine-grained token を入れる。
