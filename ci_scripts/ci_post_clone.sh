#!/bin/sh
# Xcode Cloud がクローンした直後に実行される。
# .xcodeprojはリポジトリに入れず project.yml から生成する方針なので、ここで生成する。
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"
brew install xcodegen
xcodegen generate
