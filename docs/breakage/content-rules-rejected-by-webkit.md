# WinBrowse: one rejected filter rule removed every exception

| | |
|---|---|
| Site | any site that needs an exception rule to work |
| Class | WinBrowse bug in rule compilation |
| Status | fixed in `4559023` |
| Regression test | `RuleListCompilerTests.dropsOnlyTheRulesWebKitRejects`, `RuleConverterTests.webKitCompilesEveryRuleTheConverterEmits` |

## Symptom

Unknown in the field. On a WebKit version that rejects some converted rules, sites that rely on uBlock Origin's exception rules could break.

## Reproduction

The unit test hides one rule WebKit refuses (`ad{2}`) among valid rules.

## Cause

Found by reading the code. When a single block rule failed to compile and no list had compiled yet, the old loop concluded that the exception rules were at fault and compiled every list without any exceptions. It also counted the exceptions once per list in the rule total.

## Fix

Exceptions are compiled alone first and only those WebKit refuses are dropped. A list that fails is split until only the refused block rules are left out. The compile report on the uBlock screen and in breakage reports shows how many rules were refused and WebKit's first error message. Still open: whether iOS 17 rejects lists that mix `if-top-url` and `if-domain` conditions; the WebKit compile test answers that on an iOS 17 simulator.
