# Fronix Architecture And Roadmap

Fronix is a successor-style project to LiveVue. The goal is to keep the useful LiveView integration model while making the frontend framework pluggable. The backend should be shared; framework differences should live in frontend adapters and in small backend convenience components.

This document captures the initial architecture decisions and the feature support plan.

## Goals

- One Hex package, like LiveVue.
- No npm publishing requirement.
- One frontend source tree shipped inside the Hex package.
- A shared backend implementation for component rendering, prop encoding, prop diffs, streams, SSR dispatch, and installation.
- Framework-specific frontend adapters for Vue, React, Svelte, and future frameworks.
- Strong boundaries so framework adapters do not import each other.
- E2E tests that prove the same backend protocol works across adapters.

## Packaging

Fronix should expose frontend entrypoints from the root package used through `file:./deps/fronix`.

Consumer `package.json` should look roughly like:

```json
{
  "dependencies": {
    "fronix": "file:./deps/fronix",
    "vue": "...",
    "@vitejs/plugin-vue": "..."
  }
}
```

The root package should export framework-specific entrypoints:

```json
{
  "name": "fronix",
  "exports": {
    "./vue": "./assets/vue/index.ts",
    "./vue/server": "./assets/vue/server.ts",
    "./react": "./assets/react/index.ts",
    "./react/server": "./assets/react/server.ts",
    "./svelte": "./assets/svelte/index.ts",
    "./svelte/server": "./assets/svelte/server.ts"
  }
}
```

Users should not need to import a separate core package. Framework entrypoints import shared internals themselves.

## Proposed Source Layout

```text
fronix/
  lib/
    fronix.ex
    fronix/component.ex
    fronix/components.ex
    fronix/encoder.ex
    fronix/slots.ex
    fronix/shared_props_view.ex
    fronix/ssr.ex
    fronix/ssr/node_js.ex
    fronix/ssr/quick_beam.ex
    fronix/ssr/vite_js.ex
    mix/tasks/fronix.install.ex

  assets/
    core/
      attrs.ts
      hook.ts
      registry.ts
      json_patch.ts
      live.ts
      runtime.ts
      store.ts
      streams.ts
      types.ts
      uploads.ts
      utils.ts
    vue/
      index.ts
      adapter.ts
      server.ts
      use_live.ts
      use_live_form.ts
      use_live_upload.ts
    react/
      index.ts
      adapter.tsx
      server.tsx
      use_live.ts
      use_live_form.ts
      use_live_upload.ts
    svelte/
      index.ts
      adapter.ts
      server.ts
      live.ts
      use_live_form.ts
      use_live_upload.ts

  test/e2e/
    support/
    features/
      basic/
        live.ex
        basic.spec.ts
        vue/Counter.vue
        react/Counter.tsx
        svelte/Counter.svelte
      prop_diff/
      streams/
      events/
      forms/
      uploads/
      slots/
      ssr/
```

The layout can stay under `assets/` rather than npm workspaces. The important boundary is logical and enforced by tests/linting:

- `assets/core` imports no framework.
- `assets/vue` imports `assets/core` and Vue only.
- `assets/react` imports `assets/core` and React only.
- `assets/svelte` imports `assets/core` and Svelte only.
- No adapter imports another adapter.

## Backend API

Use framework-neutral `f-*` attributes for Fronix control options. The prefix prevents collisions with arbitrary component props without leaking Vue-specific naming.

```elixir
<.vue f-component="Counter" count={@count} />
<.react f-component="Counter" count={@count} />
<.svelte f-component="Counter" count={@count} />
```

Reserved Fronix attributes:

- `f-component`
- `f-socket`
- `f-ssr`
- `f-diff`
- `f-inject`
- `f-inject:*`

All non-reserved attributes become frontend props, with special treatment for wrapper HTML attributes such as `id`, `class`, and `style`.

The docs should emphasize framework helpers:

```elixir
<.react f-component="Counter" />
```

A generic lower-level component can still exist for internals and tests:

```elixir
<Fronix.component f-framework={:react} f-component="Counter" />
```

## Frontend Hook Ownership

The public hook map should come from the framework-specific frontend entrypoint. The adapter factory should return `hooks` directly so installation does not require a separate `getHooks(...)` call.

```ts
import { createLiveReact } from "fronix/react"

const liveReact = createLiveReact({
  resolve: name => components[`./${name}.tsx`],
})

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: liveReact.hooks,
})
```

Internally, `assets/core/hook.ts` can provide the LiveView hook lifecycle, but it should be parameterized by an adapter. The public factory belongs to `fronix/vue`, `fronix/react`, `fronix/svelte`, etc. and should return both framework configuration and the Phoenix hook map.

Suggested internal adapter shape:

```ts
type FronixAdapter<Component, Instance, Runtime> = {
  hookName: string
  createRuntime(initial: InitialPayload): Runtime
  resolve(name: string): Promise<Component>
  mount(ctx: MountContext<Component, Runtime>): Instance
  update(runtime: Runtime, patch: PatchPayload): void
  destroy(instance: Instance, runtime: Runtime): void
  renderToString(ctx: SSRContext<Component>): Promise<string>
}
```

`Runtime` means the adapter-owned reactive bridge between Fronix patches and the framework. It is not backend state.

Examples:

- Vue runtime: reactive props, reactive slots, provided live handle.
- React runtime: snapshot/subscription object consumed by React context/hooks.
- Svelte runtime: readable/writable stores and context.
- Headless runtime: patchable object plus listeners.

This is intentionally approximate. The exact React/Svelte runtime strategy can be decided during implementation.

## Active Hook Registry

Core should track active LiveView-backed Fronix hooks by DOM id from the start, even if `f-inject` and persistent layouts are postponed.

```ts
activeHooks.set(elementId, liveHandle)
activeHooks.delete(elementId)
```

This registry should remain mostly internal initially, but it keeps future features possible:

- `f-inject`
- persistent layouts
- cross-component reads
- debugging tools
- headless components
- `getLive(id)` style APIs

The registry should not force public cross-component APIs in V1.

## Naming

Use Fronix names in new APIs where they fit the framework:

- `useLive()`
- `LiveContext`
- internal hook state like `this.fronix`
- `FronixVueHook`, `FronixReactHook`, `FronixSvelteHook`

Vue may still expose `$live` as a convenience because it is ergonomic in templates.

Avoid LiveVue-specific names such as `useLiveVue`, `VueHook`, `v-component`, and `v-on`.

Do not force one-to-one helper names across adapters. Keep conceptual parity, but make each adapter feel native.

Examples:

```ts
// React
const live = useLive()
const form = useLiveForm(form)

// Vue
const live = useLive()
const form = useLiveForm(() => props.form)

// Svelte
const live = getLive()
const form = createLiveForm(form)
```

React and Vue commonly use `useX` APIs. Svelte should prefer stores, context, and actions where those are more idiomatic.

## Events

Do not carry over `v-on:*` / `f-on:*`.

The feature is replaceable with `pushEvent` from frontend code and adds protocol complexity:

- backend extraction of handlers
- JS op serialization
- client-side handler injection
- framework-specific mapping of event props

Frontend components should use their framework's natural event handling and call LiveView directly:

```ts
const live = useLive()
live.pushEvent("increment", { value })
```

Native `phx-*` attributes inside rendered DOM can still work where the framework preserves attributes.

## Slots

LiveVue slots are useful but the current mechanism is a hack: render HEEX on the backend, base64 encode the rendered HTML, send it through data attributes, and render it on the frontend. This may remain useful, but it should not be treated as a clean cross-framework abstraction.

Initial approach:

- Support simple static HEEX slots only if the adapter can render them safely.
- Keep the slot protocol isolated so it can be removed or changed.
- Do not make slots a blocker for the initial React/Svelte adapters.
- Do not document slots as a core design pillar until the cross-framework semantics are proven.

Named slots are especially framework-specific:

- Vue has native named slots.
- React has children, props, and render functions.
- Svelte has slots/snippets with different compilation assumptions.

## Injection And Persistent Layouts

`v-inject` is valuable, especially for persistent layouts and component composition across LiveView navigation, but it is also a major source of complexity.

Initial approach:

- Keep it out of the first cross-framework foundation.
- Preserve the backend namespace as `f-inject` / `f-inject:*` for future use.
- Vue can support it earlier if the migration from LiveVue is direct.
- React/Svelte should not be forced into a Vue-shaped injection model.

## Forms

Backend form support should be part of Fronix. The backend can encode form data, Ecto changeset errors, and standard LiveView form structures in a framework-neutral way.

Frontend form helpers should be framework-specific:

- Vue can migrate `useLiveForm` quickly.
- React likely needs its own hook design.
- Svelte likely needs stores/actions rather than a direct hook clone.

It is acceptable for the backend to support forms from the start while some adapters expose form helpers later.

## Uploads

LiveView upload integration should remain a goal, but frontend APIs are framework-specific.

Initial approach:

- Keep shared low-level upload helpers in core if they are DOM/LiveView-only.
- Put ergonomic APIs in each adapter.
- Vue can migrate first.
- React/Svelte should receive their own idiomatic wrappers after basic adapter behavior is stable.

## SSR

The backend SSR dispatcher can be shared, but SSR implementation belongs to each adapter.

Initial approach:

- SSR is supported from the start for every initially supported adapter.
- The frontend layout must include browser and server entrypoints per adapter.
- Each adapter owns its renderer and hydration semantics.
- E2E coverage should verify SSR and hydration for each supported adapter.
- SSR should shape the adapter contract from the beginning instead of being added later.

Per-adapter entrypoints:

```text
assets/vue/index.ts
assets/vue/server.ts
assets/react/index.tsx
assets/react/server.tsx
assets/svelte/index.ts
assets/svelte/server.ts
```

Factory options may include both client and server concerns:

```ts
const liveReact = createLiveReact({
  resolve,
  setup?,
  renderToString?,
})
```

The exact option names can be refined, but SSR should not be treated as a Vue-only migration feature.

## Headless Store

A headless adapter or store API is adjacent to Fronix and worth designing for, but it should not be part of the first public promise unless component adapters are already stable.

Possible future API:

```ts
import { liveStore } from "fronix/store"

const store = liveStore("/store", { socket })

store.subscribe(state => {
  // state is patched as channel updates arrive
})

store.pushEvent("save", payload)
```

This would be useful for normal SPA islands or channel-backed state that is not tied to Phoenix LiveView hooks. It implies a broader backend scope than component embedding, so the initial architecture should keep it possible without committing to it immediately.

Suggested separation:

- `assets/core/runtime.ts`: patchable object/runtime primitives.
- `assets/core/hook.ts`: Phoenix LiveView hook-backed runtime.
- `assets/core/store.ts`: future Phoenix channel-backed runtime.

## Installer

Install one adapter at a time:

```bash
mix fronix.install vue
mix fronix.install react
mix fronix.install svelte
```

The installer should:

- install/configure Phoenix Vite
- add Fronix backend configuration
- inject `use Fronix` and `Fronix.SharedPropsView`
- add the selected frontend framework dependencies
- add `fronix: "file:./deps/fronix"` to `package.json`
- create framework-specific component bootstrap files
- wire `liveFronix.hooks` into `LiveSocket`
- create a tiny demo component and route
- configure SSR entries for the selected adapter

Multi-adapter installation in one Phoenix app can come later.

## E2E Strategy

E2E tests are required for confidence. Unit tests alone cannot prove LiveView lifecycle, Phoenix patches, frontend hydration, and framework rendering work together.

Use shared feature specs with framework-specific component fixtures:

```text
test/e2e/features/basic/
  live.ex
  basic.spec.ts
  vue/Counter.vue
  react/Counter.tsx
  svelte/Counter.svelte
```

Run Playwright projects for each adapter:

- `vue`
- `react`
- `svelte`

Routes can be namespaced:

- `/vue/basic`
- `/react/basic`
- `/svelte/basic`

The same behavior should be asserted across adapters when the feature is marked supported for that adapter.

## LiveVue Feature Matrix

Status meanings:

- `Start`: support in the initial Fronix foundation.
- `Vue Start`: support early for Vue, but not required for every adapter initially.
- `Later`: design/implement after the adapter contract is stable.
- `Drop`: intentionally not carried over.
- `Backend Start`: backend protocol/support from the start, frontend helpers may lag by adapter.

| LiveVue feature | Fronix status | Notes |
| --- | --- | --- |
| Render frontend component from LiveView | Start | Core reason for the project. Use `<.vue>`, `<.react>`, `<.svelte>` helpers over one generic public API. |
| Shared backend implementation | Start | Backend rendering, encoding, diffs, streams, SSR dispatch, and installer should be shared. |
| Framework-specific client hook | Start | Public hook comes from `fronix/vue`, `fronix/react`, etc.; core provides internal lifecycle machinery. |
| `v-component` | Replace | Use `f-component`. Keep `v-component` only as a possible LiveVue migration alias, not primary API. |
| `v-socket` | Replace | Use `f-socket`, usually injected automatically by `SharedPropsView`. |
| `v-ssr` | Replace | Use `f-ssr`. SSR should be available for every initially supported adapter. |
| `v-diff` | Replace | Use `f-diff`. |
| `v-on:*` event handlers | Drop | Prefer adapter `useLive().pushEvent(...)` and native frontend event handling. |
| Props serialization | Start | Backend protocol should be framework-neutral. |
| Props diffing with JSON Patch | Start | High-value shared feature. The patch application belongs in frontend core; reactivity integration belongs in adapters. |
| Phoenix LiveStream patches | Start | High-value shared backend/core feature, but every adapter needs E2E coverage. |
| `LiveVue.Encoder` protocol | Start | Rename to `Fronix.Encoder`; keep explicit struct encoding and security model. |
| Shared props via `SharedPropsView` | Start | Rename to `Fronix.SharedPropsView`; inject `f-socket` and configured props into Fronix tags. |
| Component shortcut generation from files | Start | Generalize file extensions per adapter: `.vue`, `.tsx/.jsx`, `.svelte`. |
| `~VUE` sigil | Later | Nice DX but adapter-specific and not essential to prove Fronix. Avoid multiplying sigils early. |
| Server-side rendering | Start | Required from the start for every initially supported adapter because it shapes frontend organization and adapter contracts. |
| Lazy-loaded components | Start | This mostly falls out of adapter `resolve(name)` returning promises. |
| Vite integration/plugin | Start | Needed for practical install. Keep adapter-specific Vite setup. |
| Tailwind support | Start | Installer should avoid breaking Tailwind. No special core abstraction needed. |
| Static HEEX slots | Later | Useful but hacky. Support only after semantics are clear per adapter. Vue may get it earlier as migration parity. |
| Named slots | Later | Harder to make framework-neutral. |
| Slot non-ASCII handling | Later | Relevant if static slots are supported. |
| `v-inject` / injected components | Later, Vue Start optional | Valuable but complex. Do not force React/Svelte to match Vue's model early. |
| Persistent layouts | Later, Vue Start optional | Depends on injection/headless component semantics. |
| Headless components / shared reactive props | Later | Useful, but tied to cross-component lookup and injection semantics. |
| `useLiveVue` | Replace | Use `useLive`. |
| `useLiveEvent` | Start | Adapter-specific helper over LiveView `handleEvent`; name and shape can vary by adapter when a non-`useX` API is more idiomatic. |
| `useEventReply` | Start | Adapter-specific helper. Useful and small; name and shape can vary by adapter. |
| `useLiveNavigation` | Start | Adapter-specific helper over LiveSocket navigation; name and shape can vary by adapter. |
| `useLiveConnection` | Start | Adapter-specific helper over LiveSocket connection state; name and shape can vary by adapter. |
| `useLiveForm` | Backend Start, Vue Start | Backend form encoding from start. Vue/React can use hook/composable APIs; Svelte should use stores/context/actions if more native. |
| `useField` / `useArrayField` | Vue Start, Later elsewhere | Framework-specific form ergonomics. Do not force one-to-one APIs across adapters. |
| `useLiveUpload` | Vue Start, Later elsewhere | Low-level LiveView upload behavior can be shared; ergonomic APIs should be per adapter. |
| Link component | Later | Framework-specific and lower priority. Phoenix already has navigation primitives. |
| Active hook registry by id | Start | Internal core registry for future injection/persistent-layout/headless features. Not necessarily public in V1. |
| Headless store / SPA channel store | Later | Design core runtime so this is possible, but do not expand the first public scope beyond LiveView components. |
| QuickBEAM SSR | Start | Keep backend support and require adapter server renderers to be tested. |
| NodeJS SSR | Start | Same as QuickBEAM. |
| Vite dev SSR | Start | Same as QuickBEAM. |
| VS Code extension for sigil | Later | Only relevant if new sigils exist. |
| Install script | Start | Required. Use `mix fronix.install <adapter>`. |
| E2E tests | Start | Required for every supported adapter feature. |

## Vue-First Compatibility

It is not inherently harmful to ship more features for Vue early and mark them as TODO for other adapters, but it creates real product and maintenance risks.

Benefits:

- Fast migration from LiveVue.
- Existing LiveVue code can be reused.
- Vue users get a nearly complete replacement quickly.
- The project can validate the package, installer, backend, and E2E setup against known behavior.

Risks:

- Fronix may look like LiveVue with placeholders for other frameworks.
- Shared core can accidentally become Vue-shaped.
- Later React/Svelte work may require breaking the "shared" protocol.
- Documentation can become confusing if the main feature list is Vue-heavy.
- E2E parity becomes harder to reason about unless support levels are explicit.

Recommendation:

- Allow Vue to be ahead, but keep the public contract honest.
- Mark feature support per adapter in docs and tests.
- Do not let Vue-only features define core abstractions until at least one non-Vue adapter validates them.
- Require every shared protocol change to have at least Vue and React E2E coverage, even if higher-level Vue helpers are more complete.
- Keep Vue-only migrated features physically inside `assets/vue` unless they are proven framework-neutral.

This gives Fronix a pragmatic path: Vue can bootstrap the project quickly, while React/Svelte still protect the architecture from becoming Vue-specific.
