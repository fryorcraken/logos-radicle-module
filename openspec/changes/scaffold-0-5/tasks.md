## Stages

- [ ] ~~spec — `spec-writer`~~ — no behaviour contract moves: a toolchain and
      pin change, so `skip_specs: true` in `.openspec.yaml`. The proposal is
      written; a behaviour change Basecamp 0.3.0 forces comes back here.
- [ ] design + code — `dev-writer`
- [ ] tests — `tester`
- [ ] review: correctness — `code-reviewer`
- [ ] review: security — `code-reviewer`
- [ ] review: readability — `code-reviewer`
- [ ] review: architecture — `code-reviewer`
- [ ] review: spec-test — `spec-test-reviewer`
- [ ] review: design — `design-reviewer`
- [ ] findings all ticked, `findings/` deleted — `closer`
- [ ] `openspec validate --strict`, then `archive` — `closer`
- [ ] CI green, title/body checked, PR merged — `closer`
