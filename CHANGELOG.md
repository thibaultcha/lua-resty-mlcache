# Table of Contents

- [Unreleased](#unreleased)
- [2.0.0](#2.0.0)
- [1.0.1](#1.0.1)
- [1.0.0](#1.0.0)

## Unreleased

Diff: [2.0.0...master]

[Back to TOC](#table-of-contents)

## [2.0.0]

> Released on: 2018/03/18

This release implements numerous new features. The major version digit has been
bumped to ensure that the changes to the interpretation of the callback return
values (documented below) do not break any dependent application.

#### Added

- Implement a new `purge()` method to clear all cached items in both
  the L2 and L3 caches.
  [#34](https://github.com/thibaultcha/lua-resty-mlcache/pull/34)
- Implement a new `shm_miss` option. This option receives the name
  of a lua_shared_dict, and when specified, will cache misses there instead of
  the instance's `shm` shared dict. This is particularly useful for certain
  types of workload where a large number of misses can be triggered and
  eventually evict too many cached values (hits) from the instance's `shm`.
  [#42](https://github.com/thibaultcha/lua-resty-mlcache/pull/42)
- Implement a new `l1_serializer` callback option. It allows the
  deserialization of data from L2 or L3 into arbitrary Lua data inside the LRU
  cache (L1). This includes userdata, cdata, functions, etc...
  Thanks to [@jdesgats](https://github.com/jdesgats) for the contribution.
  [#29](https://github.com/thibaultcha/lua-resty-mlcache/pull/29)
- Implement a new `shm_set_tries` option to retry `shm:set()`
  operations and ensure LRU eviction when caching unusually large values.
  [#41](https://github.com/thibaultcha/lua-resty-mlcache/issues/41)
- The L3 callback can now return `nil + err`, which will be bubbled up
  to the caller of `get()`. Prior to this change, the second return value of
  callbacks was ignored, and users had to throw hard Lua errors from inside
  their callbacks.
  [#35](https://github.com/thibaultcha/lua-resty-mlcache/pull/35)
- Support for custom IPC module.
  [#31](https://github.com/thibaultcha/lua-resty-mlcache/issues/31)

[Back to TOC](#table-of-contents)

## [1.0.1]

> Released on: 2017/08/26

#### Fixed

- Do not rely on memory address of mlcache instance in invalidation events
  channel names. This ensures invalidation events are properly broadcasted to
  sibling instances in other workers.
  [#27](https://github.com/thibaultcha/lua-resty-mlcache/pull/27)

[Back to TOC](#table-of-contents)

## [1.0.0]

> Released on: 2017/08/23

Initial release.

[Back to TOC](#table-of-contents)

[2.0.0...master]: https://github.com/thibaultcha/lua-resty-mlcache/compare/2.0.0...master
[2.0.0]: https://github.com/thibaultcha/lua-resty-mlcache/compare/1.0.1...2.0.0
[1.0.1]: https://github.com/thibaultcha/lua-resty-mlcache/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/thibaultcha/lua-resty-mlcache/tree/1.0.0
