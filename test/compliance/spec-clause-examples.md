# POSIX spec-clause examples

This note records hand-curated examples added from current high-risk POSIX shell clauses. These are not imported from an external harness; they are small Rush corpus cases tied to manifest rows.

## Added examples

| case | corpus | manifest rows | purpose |
| --- | --- | --- | --- |
| `pathname-slash-components` | `test/corpus/posix` | `expansion-pathname`, `expansion-pathname-slash-components` | slash-separated pathname expansion components |
| `pathname-dotfiles` | `test/corpus/posix` | `expansion-pathname`, `expansion-pathname-dotfiles` | leading-period matching rule |
| `pathname-unmatched-slash` | `test/corpus/posix` | `expansion-pathname-slash-components` | unmatched slash-containing patterns remain literal |
| `case-leading-paren-empty-arm` | `test/corpus/posix` | `grammar-case`, `grammar-case-empty-arms` | optional leading `(` and empty case body |
| `case-final-arm-no-terminator` | `test/corpus/posix` | `grammar-case-pattern-list` | final case arm without `;;` terminator |
| `case-nested-case-body` | `test/corpus/posix` | `grammar-case` | nested case command inside an outer case item body |
| `grammar-case-missing-pattern-end` | `test/corpus/posix-negative` | `grammar-case-empty-arms` | malformed case item diagnostic |
| `grammar-case-missing-in` | `test/corpus/posix-negative` | `grammar-case` | missing `in` diagnostic for malformed case command |
| `grammar-case-missing-esac` | `test/corpus/posix-negative` | `grammar-case` | missing `esac` diagnostic for incomplete case command |
| `errors-special-builtin-expansion` | `test/corpus/posix-negative` | `errors-special-builtin-expansion` | special builtin `${parameter:?word}` expansion failure exits non-interactive execution |
| `errors-special-builtin-expansion-{eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-expansion` | utility-specific special builtin `${parameter:?word}` expansion failures exit non-interactive execution |
| `errors-special-builtin-redirection-{eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | utility-specific special builtin noclobber redirection failures exit non-interactive execution |
| `errors-special-builtin-redirection-input` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | special builtin missing input redirection failure exits non-interactive execution |
| `errors-special-builtin-redirection-bad-fd` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | special builtin bad fd duplication failure exits non-interactive execution |
| `errors-special-builtin-redirection-input-{eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | utility-specific missing input redirection failures exit non-interactive execution |
| `errors-special-builtin-redirection-bad-fd-{eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | utility-specific bad fd redirection failures exit non-interactive execution |
| `errors-special-builtin-redirection-bad-input-fd{-eval,-export,-readonly,-set,-unset,-trap}` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | utility-specific bad input fd redirection failures exit non-interactive execution |
| `redirection-input-missing` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | ordinary command missing input redirection reports an error and continues |
| `redirection-bad-input-fd-duplication` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | ordinary command bad input fd duplication reports an error and continues |
| `redirection-{output,append}-directory` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | ordinary command directory output redirections report an error and continue |
| `errors-special-builtin-redirection-{output,append}-directory` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | special builtin directory output redirection failures exit non-interactive execution |
| `errexit-negation-suppression` | `test/corpus/posix` | `option-errexit-conditions` | `set -e` is suppressed for negated pipelines |
| `errexit-and-or-suppression` | `test/corpus/posix` | `option-errexit-conditions` | `set -e` is suppressed for commands before `&&` and `||` in AND-OR lists |
| `errexit-and-or-final-exits` | `test/corpus/posix` | `option-errexit-conditions` | final failing AND-OR list commands still exit non-interactive execution |

## Known follow-up examples

- Add more special-builtin expansion failure classes beyond `${parameter:?word}`.
- Add redirection consequence examples for non-special utilities versus special builtins across more redirection operators.
- Add alias token-recognition timing examples after parser alias handling is deepened.
