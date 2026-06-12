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
| `case-subject-in-word` | `test/corpus/posix` | `grammar-case` | `in` may be the case subject word before the delimiter `in` |
| `case-subject-esac-word` | `test/corpus/posix` | `grammar-case` | `esac` may be the case subject word before the delimiter `in` |
| `grammar-case-character-classes` | `test/corpus/posix` | `grammar-case`, `grammar-case-pattern-list`, `grammar-case-bracket-patterns` | POSIX character classes inside case bracket patterns |
| `grammar-case-empty-list` | `test/corpus/posix` | `grammar-case` | case command with no case items exits successfully |
| `grammar-reserved-literal-contexts` | `test/corpus/posix` | `grammar-for-reserved-word-list-literals`, `grammar-case-reserved-word-body-literals` | reserved-looking words are literal in for word lists and case item body arguments |
| `grammar-for-exit-status` | `test/corpus/posix` | `grammar-for`, `grammar-for-exit-status` | for loop status is the last body status, or zero when no words are iterated |
| `grammar-brace-group-separators` | `test/corpus/posix` | `grammar-brace-group` | brace groups recognize `{` and `}` as reserved words when separated by POSIX separators, including semicolon and newline before `}` |
| `grammar-brace-group-pipeline-stage` | `test/corpus/posix` | `grammar-brace-group` | brace groups execute exactly once as first and non-first pipeline stages |
| `grammar-compound-pipeline-first-stage` | `test/corpus/posix` | `grammar-compound-pipeline-first-stage` | representative POSIX compound commands parse and execute as first pipeline stages |
| `grammar-compound-pipeline-nonfirst-stage` | `test/corpus/posix` | `grammar-compound-pipeline-nonfirst-stage` | representative POSIX subshell, for, case, and function-definition commands parse and execute as middle pipeline stages |
| `expansion-parameter-pattern-character-classes` | `test/corpus/posix` | `expansion-parameter-pattern`, `expansion-parameter-pattern-bracket-expression` | POSIX character classes inside parameter pattern-removal operands |
| `pathname-character-classes` | `test/corpus/posix` | `expansion-pathname`, `expansion-pathname-bracket-expressions` | POSIX character classes inside pathname bracket patterns |
| `strict-syntax-stops-execution` | `test/corpus/posix` | `errors-syntax` | strict POSIX syntax diagnostics return status 2 and prevent non-interactive execution before or after the malformed command |
| `grammar-brace-group-missing-list-terminator` | `test/corpus/posix-negative` | `grammar-brace-group`, `grammar-grouping-strict-diagnostics` | missing semicolon or newline before `}` is diagnosed as an incomplete brace group in strict POSIX mode |
| `grammar-case-missing-pattern-end` | `test/corpus/posix-negative` | `grammar-case-empty-arms` | malformed case item diagnostic |
| `grammar-case-missing-in` | `test/corpus/posix-negative` | `grammar-case` | missing `in` diagnostic for malformed case command |
| `grammar-case-missing-esac` | `test/corpus/posix-negative` | `grammar-case` | missing `esac` diagnostic for incomplete case command |
| `expansion-redirection-target-error` | `test/corpus/posix-negative` | `errors-expansion` | redirection target word expansion failure exits non-interactive execution |
| `expansion-assignment-word-error` | `test/corpus/posix-negative` | `errors-expansion` | assignment word expansion failure exits non-interactive execution |
| `expansion-parameter-assign-positional-*` / `expansion-parameter-assign-special-*` | `test/corpus/posix-negative` | `errors-expansion`, `expansion-parameter-assignment-operator` | assignment parameter expansion to positional/special parameters fails when assignment would be needed |
| `expansion-for-list-error` | `test/corpus/posix-negative` | `errors-expansion` | for-loop word-list expansion failure exits non-interactive execution before running the loop body |
| `expansion-case-subject-error` / `expansion-case-pattern-error` | `test/corpus/posix-negative` | `errors-expansion` | case subject and pattern expansion failures exit non-interactive execution before selecting/running an arm |
| `expansion-command-substitution-parameter-error` | `test/corpus/posix-negative` | `errors-expansion` | command-substitution parameter expansion failure exits only the substitution subshell while surfacing diagnostics and assignment-only status |
| `errors-special-builtin-expansion` | `test/corpus/posix-negative` | `errors-special-builtin-expansion` | special builtin `${parameter:?word}` expansion failure exits non-interactive execution |
| `errors-special-builtin-expansion-{eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-expansion` | utility-specific special builtin `${parameter:?word}` expansion failures exit non-interactive execution |
| `errors-special-builtin-nounset-{colon,eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-expansion` | utility-specific special builtin nounset expansion failures exit non-interactive execution |
| `errors-special-builtin-redirection-{eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | utility-specific special builtin noclobber redirection failures exit non-interactive execution |
| `errors-special-builtin-redirection-input` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | special builtin missing input redirection failure exits non-interactive execution |
| `errors-special-builtin-redirection-bad-fd` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | special builtin bad fd duplication failure exits non-interactive execution |
| `errors-special-builtin-redirection-input-{eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | utility-specific missing input redirection failures exit non-interactive execution |
| `errors-special-builtin-redirection-bad-fd-{eval,export,readonly,set,unset,trap}` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | utility-specific bad fd redirection failures exit non-interactive execution |
| `errors-special-builtin-redirection-bad-input-fd{-eval,-export,-readonly,-set,-unset,-trap}` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | utility-specific bad input fd redirection failures exit non-interactive execution |
| `builtin-times-too-many-arguments` | `test/corpus/posix-negative` | `errors-special-builtin`, `builtin-times-usage-errors` | special builtin utility operand failure exits non-interactive execution |
| `builtin-trap-invalid-signal-exits` | `test/corpus/posix-negative` | `errors-special-builtin`, `builtin-trap-invalid-signal` | special builtin utility semantic failure exits non-interactive execution |
| `redirection-input-missing` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | ordinary command missing input redirection reports an error and continues |
| `redirection-bad-input-fd-duplication` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | ordinary command bad input fd duplication reports an error and continues |
| `redirection-{output,append}-directory` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | ordinary command directory output redirections report an error and continue |
| `redirection-compound-missing-input` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | brace group, if, while, and for input redirection failures fail the compound command without exiting |
| `redirection-function-call-vs-body` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | function call/definition redirection failure is distinct from redirection failure inside the function body |
| `redirection-read-write-missing-parent` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | `<>` open failure for non-special builtin and external commands fails the command and continues |
| `errors-special-builtin-redirection-read-write-missing-parent` | `test/corpus/posix-negative` | `errors-redirection-noninteractive`; `errors-special-builtin-redirection` | `<>` open failure on a special builtin exits non-interactive execution |
| `redirection-builtins-groups-real-fd` | `test/corpus/posix` | `redirection-builtins-groups` | inherited-stdio redirections on builtins, functions, brace groups, subshells, and if/for/while/until/case compounds use real shared fds for arbitrary fd output and mixed builtin/external stdin consumers |
| `redirection-here-doc-double-quoted-backslash-delimiter` | `test/corpus/posix` | `redirection-here-doc` | double-quoted here-doc delimiter quote removal preserves non-special backslashes when finding the terminating delimiter |
| `redirection-status-propagation` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | redirection failure status through AND-OR lists, negation, and `$?` |
| `redirection-errexit{,-suppressed-contexts}` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | `errexit` fires for ordinary redirection failures except in suppressed AND-OR and negation contexts |
| `redirection-pipeline-missing-input-last` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | last-stage pipeline redirection failure determines pipeline status |
| `redirection-{,async-}heredoc-materialization-failure` | `test/corpus/posix-negative` | `errors-redirection-noninteractive` | here-doc fd materialization failure path reports a redirection diagnostic |
| `output-write-failure-dev-full-statuses` | `test/corpus/posix-negative` | `errors-output-write-failure` | Linux-gated `/dev/full` actual file target write failures preserve builtin, function, compound, external, and pipeline statuses |
| `errors-special-builtin-redirection-{output,append}-directory` | `test/corpus/posix-negative` | `errors-special-builtin-redirection` | special builtin directory output redirection failures exit non-interactive execution |
| `builtin-printf-missing-operands` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-format-reuse`, `builtin-printf-missing-operands`, `builtin-printf-numeric-formats` | printf supplies empty string and zero defaults for missing conversion operands |
| `builtin-printf-percent-literal` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-percent-literal` | `%%` emits a literal percent without consuming an operand |
| `builtin-printf-i-conversion` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-i-conversion`, `builtin-printf-numeric-formats` | `%i` formats signed integer operands including POSIX C hexadecimal constants |
| `builtin-printf-integer-format-flags`; `builtin-printf-integer-flag-order`; `builtin-printf-integer-sign-padding` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-numeric-formats`, `builtin-printf-integer-format-flags` | signed integer conversions honor representative sign and space flags; integer conversions honor representative octal/hex alternate-form, precision, field-width, left-adjust, zero-padding flags, reordered flag combinations, and sign/precision padding interactions |
| `builtin-printf-integer-zero-precision` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-width-precision`, `builtin-printf-numeric-formats`, `builtin-printf-integer-zero-precision` | zero-valued integer conversions with zero precision suppress decimal/hexadecimal digits while alternate octal keeps one zero |
| `builtin-printf-omitted-precision-digits` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-width-precision`, `builtin-printf-numeric-formats`, `builtin-printf-omitted-precision-digits` | a precision period with no following digits behaves as zero precision for representative string and integer conversions |
| `builtin-printf-dynamic-width-precision`; `builtin-printf-dynamic-combined-width-precision`; `builtin-printf-negative-dynamic-width-precision` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-width-precision`, `builtin-printf-dynamic-width-precision` | asterisk width and precision consume integer arguments before representative string and signed-integer conversion operands, including combined dynamic string width/precision, negative width-as-left-adjustment, negative precision-as-omitted, and left-adjusted signed integer precision |
| `builtin-printf-floating-format-flags` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-floating-conversions`, `builtin-printf-floating-format-flags` | floating conversions honor representative sign/space/alternate flags with C-locale radix output |
| `builtin-printf-string-width-precision` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-width-precision` | string conversions combine width, precision, left adjustment, and zero precision |
| `builtin-printf-b-precision` | `test/corpus/posix` | `builtin-printf`, `builtin-printf-b-c-conversions`, `builtin-printf-b-precision`, `builtin-printf-width-precision` | `%b` applies precision after escape expansion before width and left-adjust padding |
| `errexit-negation-suppression` | `test/corpus/posix` | `option-errexit-conditions` | `set -e` is suppressed for negated pipelines |
| `errexit-and-or-suppression` | `test/corpus/posix` | `option-errexit-conditions` | `set -e` is suppressed for commands before `&&` and `||` in AND-OR lists |
| `errexit-and-or-final-exits` | `test/corpus/posix` | `option-errexit-conditions` | final failing AND-OR list commands still exit non-interactive execution |
| `errexit-compound-ignored-status` | `test/corpus/posix` | `option-errexit-compound-ignored-status` | non-subshell compound commands do not trigger `errexit` when their non-zero status comes from an ignored `-e` context |
| `errexit-{subshell,function}-ignored-status-exits` | `test/corpus/posix` | `option-errexit-compound-ignored-status` | subshell commands and function calls remain `errexit` boundaries for ignored-status failures |
| `errexit-{pipeline-status,command-substitution-subshell}` | `test/corpus/posix` | `option-errexit-pipeline-substitution` | `errexit` considers pipeline status, and command-substitution failures exit only the substitution subshell when the containing command succeeds |

## Known follow-up examples

- Add redirection consequence examples for non-special utilities versus special builtins across more redirection operators.
- Add alias token-recognition timing examples after parser alias handling is deepened.
