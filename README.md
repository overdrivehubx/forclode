# Trade UI — Offline Simulation Harness

A single, standalone Luau script (`TradeDebugHarness.luau`) that drives the
existing Murder-Mystery-2 style **Trade interface entirely client-side** for
UI/UX testing and video capture. It fires **no** `RemoteEvent:FireServer()` or
`RemoteFunction:InvokeServer()` — the whole backend is replaced by a local
table, `_G.DebugTradeTable`, that mirrors the real MM2 trade structure.

## What it does

- **Network isolation.** Every server round-trip in the original trade scripts
  (`OfferItem`, `AcceptTrade`, `SendRequest`, `GetTradeStatus`, `GetSyncData`, …)
  is replaced by a local function that mutates `_G.DebugTradeTable` and
  re-renders the UI.
- **Faithful state shape.** The state table matches the server's `DataModule`
  trade record exactly:

  ```lua
  _G.DebugTradeTable = {
    Locked    = false,
    LastOffer = os.time(),
    Player1   = { Player = LocalPlayer, Offer = { {ItemKey, Amount, Category}, ... }, Accepted = false },
    Player2   = { Player = <fake>,      Offer = { ... },                              Accepted = false },
  }
  ```

  Offer entry order is the live game's: `[1]=ItemKey`, `[2]=Amount`,
  `[3]=Category` (`"Weapons"` / `"Pets"`).
- **No `script` context.** All UI references resolve dynamically from
  `game.Players.LocalPlayer.PlayerGui`. The Trade `ScreenGui` is auto-detected
  across layouts (`Trade`, `TradeGUI_Phone`, or any GUI exposing the
  `Container.Trade.Offer1` path).
- **Template extraction.** Inventory frames start empty, so before clearing the
  canvas the harness captures the native item-slot template from the UI tree
  (an existing slot → a trade offer slot → a storage copy → a synthesized
  `Instance.new` fallback).
- **Idempotence.** On entry it destroys any existing `TradeDebugPanel` and
  disconnects the previous run's connections, so it can be re-run any number of
  times in one session.

## The debug controller (dark-slate panel, `UICorner`)

| Control | Effect |
|---|---|
| **Player 2 name** (TextBox) | Overrides the profile name shown for the second participant. |
| **Prompt Request + Open Trade** | Shows the native trade-request modal, then opens the trade panel. |
| **Mode: Player 1 / Player 2** | Redirects inventory-slot clicks to the **left** or **right** side of the offer table. |
| **Force P2 Accept (green)** | Lights the remote client's green acceptance flag (`Player2.Accepted = true`). |
| **Terminate + Wipe** | Plays the close animation, wipes the state tables, and removes the panel. |

The window is draggable so you can park it outside the capture frame.

## Running it

Paste the contents of `TradeDebugHarness.luau` into a `LocalScript` (or an
executor) and run it once, in a session where the game's Trade GUI already
exists in `PlayerGui`. Then use the on-screen **TradeDebugPanel**:

1. Type the second player's name.
2. **Prompt Request + Open Trade.**
3. Click inventory items to stack them into the current side; toggle **Mode**
   to fill the other side.
4. **Force P2 Accept** to show the green flag; use the in-panel Accept/Confirm
   for your own side.
5. **Terminate + Wipe** when done.

## Source analysis (what was mapped)

Derived from the provided decompiled scripts:

- `GUI2/MainPC/Menu_Trade`, `GUI2/MainMobile/TradePhone`, `GUI2/MainXbox/Trade`,
  legacy `GUI/*` — trade rendering, offer slots, request modal, accept flow.
- `GameScript/DataModule` — the authoritative `Trades[]` table shape,
  `OfferItem` stacking rules (max 4 stacks/side, reset-on-change), and
  acceptance flags.
- `Sync/Item` — item fields (`ItemName`, `Image`, `ItemType`, `Rarity`,
  `Chroma`, …). A representative slice is embedded so slots render offline.

> This harness only manipulates the local `PlayerGui`. It sends nothing to the
> server and cannot affect real trades, other players, or saved data.
