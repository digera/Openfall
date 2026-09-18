# Player Name Input - Test Plan

## Overview
This feature allows players to type their name on the team-select screen before joining. Names are validated by the server and replicated to all clients.

## Changes Summary
- Protocol version bumped: v8 → v9
- Max name length: 16 characters
- Client join packet now includes name
- Server validates and sanitizes names (ASCII 32-126 only)
- Names replicated in snapshots to all clients
- Empty names fall back to "Player-XX" format
- Bots automatically named "Wisp-XX"

## Test Scenarios

### 1. Basic Name Input (Happy Path)
**Setup**: Start server, launch 2 clients

**Client 1**:
1. Connect → team-select screen appears
2. Type "Alice"
3. Verify name field shows "Alice_" (with cursor)
4. Press `1` to join Ember
5. Verify connection successful

**Client 2**:
1. Connect → team-select screen appears
2. Type "Bob"
3. Press `2` to join Tide
4. Move to see Client 1
5. Aim at Client 1 → target panel should show "Alice"

**Client 1**:
1. Aim at Client 2 → target panel should show "Bob"

**Expected**: Both clients see each other's typed names

---

### 2. Empty Name (Fallback)
**Setup**: Start server, launch 1 client

**Client 1**:
1. Connect → team-select screen appears
2. Do NOT type any name
3. Press `1` to join Ember
4. Server should assign "Player-XX" (where XX is entity ID)

**Verification**:
- Check server console → should log: `Client X.X.X.X:XXXXX joined Ember as 'Player-XX' (entity XX)`
- Launch Client 2, aim at Client 1 → should see "Player-XX" in target panel

---

### 3. Name Length Limit
**Setup**: Start server, launch 1 client

**Client 1**:
1. Connect → team-select screen
2. Type 20 characters: "ABCDEFGHIJKLMNOPQRST"
3. Verify only first 16 appear: "ABCDEFGHIJKLMNOP"
4. Verify cursor disappears (no more input allowed)
5. Press `1` to join

**Expected**: Name truncated to 16 chars client-side

---

### 4. Control Character Sanitization
**Setup**: Start server, launch 1 client

**Test invalid characters**: Tabs, newlines, unprintable ASCII
1. These are automatically filtered client-side (input handler only accepts 32-127)

**Server-side sanitization** (if client sends invalid):
- Server strips characters outside ASCII 32-126
- Empty result → fallback to "Player-XX"

---

### 5. Backspace Editing
**Setup**: Start server, launch 1 client

**Client 1**:
1. Connect → team-select screen
2. Type "Hello"
3. Press Backspace 3 times
4. Verify field shows "He_"
5. Type "nry"
6. Verify field shows "Henry_"
7. Press `1` to join

**Expected**: Name editing works correctly

---

### 6. Multiple Clients Same Name
**Setup**: Start server, launch 2 clients

**Both clients**:
1. Type "Alice"
2. Press `1` and `2` respectively to join different teams

**Expected**: Both clients have name "Alice" (no uniqueness enforcement)

---

### 7. Bot Names
**Setup**: Start server with bots (default has 1 bot per team)

**Client 1**:
1. Join any team
2. Look around for bots
3. Aim at bot → target panel should show "Wisp-XX"

**Expected**: Bots have generated "Wisp-XX" names

---

### 8. Name Persistence Across Snapshots
**Setup**: Start server, launch 2 clients far apart

**Client 1**: Type "Charlie", join Ember, run to far corner
**Client 2**: Type "Delta", join Tide, stay at spawn

1. Client 2 aims at Client 1 (long distance)
2. Client 1 should be visible in snapshot
3. Target panel shows "Charlie"
4. Client 1 moves behind cover, then back out
5. Name still shows "Charlie" (not reset to "Player-XX")

**Expected**: Names persist as long as entity is in snapshot

---

### 9. Rejoin Same Session
**Setup**: Start server, launch 1 client

**Client 1**:
1. Type "Eve", join Ember
2. Close client (disconnect)
3. Restart client, type "Eve" again
4. Join Ember

**Expected**: Server treats this as new connection with new entity ID
- Old "Eve" entity destroyed
- New "Eve" entity created (different ID)

---

### 10. Special Characters
**Setup**: Start server, launch 1 client

**Test names with**:
- `Alice123` → should work
- `[Bob]` → should work (brackets are ASCII 91/93)
- `Carol!@#` → should work
- `Dave O'Neil` → should work (space + apostrophe)
- `Émilie` → likely stripped (non-ASCII, depends on input handling)

**Expected**: ASCII 32-126 accepted, others stripped

---

### 11. Team Select UI
**Setup**: Start server, launch 1 client

**Verify UI elements**:
1. "Your name:" label visible
2. Input field with cursor "_" when empty
3. Typed text appears immediately
4. Instructions say "type your name (optional), then press 1, 2 or 3"

---

### 12. Concurrent Join Spam
**Setup**: Start server, launch 2 clients

**Both clients**:
1. Type different names
2. Both press `1` rapidly (spam join Ember)

**Expected**:
- Both clients join successfully
- Names correctly assigned
- No crashes or corruption

---

## Visual Verification Checklist

- [ ] Team-select screen shows name input field
- [ ] Cursor blinks or shows as "_"
- [ ] Typed characters appear in real-time
- [ ] Backspace removes characters
- [ ] 16-char limit enforced visually
- [ ] Target panel shows replicated names (not local)
- [ ] Bot names show as "Wisp-XX"
- [ ] Empty name → shows "Player-XX"

## Server Log Verification

Server console should log on join:
```
[Server] Client X.X.X.X:PORT joined TEAM as 'NAME' (entity ID, N clients)
```

Examples:
- `joined Ember as 'Alice' (entity 5, 1 clients)`
- `joined Tide as 'Player-12' (entity 12, 2 clients)` (fallback)
- `joined Verdant as 'Wisp-07' (entity 7, 3 clients)` (bot, shouldn't appear for bots)

## Regression Tests

- [ ] Protocol version mismatch: v8 client cannot join v9 server
- [ ] Snapshot size: 15 entities with 10-char names → ~1100 bytes (OK)
- [ ] Snapshot size: 22 entities with 16-char names → server sends fewer entities if >1400 bytes
- [ ] Mouse lock/unlock still works
- [ ] Team selection (1/2/3 keys) still works
- [ ] Lobby refresh still works
- [ ] Connection loss handling unchanged
- [ ] Bots spawn/despawn correctly
- [ ] Match start/end unaffected

## Known Limitations (Out of Scope)

- **No stats panel**: Names not shown in Tab scoreboard (future PR)
- **No persistence**: Names not saved between sessions
- **No profanity filter**: Server accepts any printable ASCII
- **No uniqueness check**: Multiple players can have same name
- **No color codes**: Names are plain text
- **No Unicode**: Only ASCII 32-126 supported

## Performance Notes

**Snapshot Size**:
- Old: ~1354 bytes worst-case (22 entities)
- New: ~1682 bytes worst-case (22 entities, 16-char names each)
- Typical: ~1100 bytes (15 entities, 8-char avg names)

**Bandwidth Impact**:
- +17 bytes per entity per snapshot (1 length byte + avg 8-char name + 8 bytes margin)
- At 30 Hz snapshots: +510 bytes/sec per entity replicated
- For 15 entities: +7.5 KB/sec per client (negligible)

**CPU Impact**: Minimal (string copy per entity per snapshot)

## Rollback Plan

If critical issues found:
1. Revert to main branch
2. Server/client protocol v8 remains compatible
3. Names revert to "Player-XX" / "Wisp-XX" generated format
