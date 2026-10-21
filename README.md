# nvim-claude

This is a personal Neovim plugin that uses the Claude Agents SDK to integrate Claude Code into NeoVim in a few particular ways that benefit me specifically, but I'm letting it live apart from my profile as its own plugin because it could be plugged into any Neovim config, given you have the prerequisites.

### Claude Agents SDK
Anthropic has two versions of the SDK, one in Python which is open source, and one in TypeScript which is obfuscated for some reason. I personally prefer Python, easily, not even a question. Therefore Python is a dependency, though virtual environments will take care of dependencies.

## Will this get you banned? 
Nope. The Anthropic Agents SDK is Claude Code is officially sanctioned by Anthropic, and at worst, it will charge usage credits, but they seem to have turned their back on that plan, and are being a lot more relaxed in general. The Agents SDK was never truly at risk anyway. It's literally created so that developers can integrate Claude into other things. If this does, then you'd be a martyr. I suggest making a fuss about it on X and have Theo pick up on that story.

## Why not Codex?
I already have Codex in my personal profile, but I'm developing something that will render this plugin redundant anyway and will support any provider not just Claude, but I'm having Astra create this because until my real project is finished enough to make a Neovim plugin out of, I want Haiku 5.5. I want it badly. I want it capped to 100k because beyond that it drains more usage; there is a multiplier. For the purposes of just text manipulation, and reformatting, and code cleanup, or code generation, Haiku 5.5 is such a perfect model. Luna would be perfect if it weren't so slow in the subscription. It's only fast over the API.

## Okay then, what is it?
Honestly, there's one specific thing that had me create this, which is Haiku 5.5 which is so fast, and yet so good at its intelligence level and so cheap if you stay below 100k context, that I want to have it as a general purpose collaborative editing agent. No, no, I can already imagine what you're thinking inside your head, you're thinking of a composer in some sidebar where you type text and it responds. **Throw that all out the window**, this is NOT that. I think that's an inefficient way of using models while editing... anything to be honest.

Inspired from my personal config's "NervAgent" which allows me to visually select a block of text and then hit `<leader>i` quickly to open a small little float wherever the cursor was and type something in, and then whatever I selected, plus some surrounding context, is sent to the completions or responses API of a specific model that is made available through an unreleased CLI tool `inf` (inference), I decided that I wanted to make something native with Claude Code integrated into NeoVim. I also have a bunch of Astra to burn, and I find the idea of Astra creating a plugin to integrate Claude into Neovim to be funny.

Basically, you stay in control of when you invoke Claude, and whether it should remember your previous message(s) or not or if this is a fresh conversation. You decide when to invoke it, and over what. This integration exists to make writing easier. I have RSI (no, not recursive self improvement; repetitive strain inguy) so hitting as few keys as possible, especially when I know an LLM could finish my thought for me is a no brainer.

There are only a few cases where you'd want to use Claude in the middle of writing:

1. You want its opinion on something specific.
2. You have a general question real quick and keep going until you get an answer.
3. You want it to transform a selected area somehow, such as formatting a list.
4. You want it to generate and insert something somewhere, such as a continuation of this sentence

Those are the four cases I aim to cover. NervAgent does this already, sort of, however it was built in the GPT 5.5 days and it relies on something that I never even published nor does it need to rely on it. This plugin is self contained. It talks to Python directly from Lua using a websocket, and Python is ran from a virtual environment with the Agents SDK installed into it. The exact Python version isn't known yet, but the SDK will be pinned to a working version by default.

## Usage
Effectively, I can just give you a keymap that explains itself:

| Mode   | Keybind | Description |
|--------|---------|-------------|
| V      | <leader>c  | Fast version of the below; if you hit it fast enough, before WhichKey show up (the time is a native Neovim setting) then this will trigger the below which is the most common. |
| V      | <leader>cc | Explicit version: transform/change visual selection; feed the selection as input, the surroundings as contex, and the prompt in the little float as instructions. |
| N      | <leader>c  | In normal mode, if you hit it fast enough, without a visual selection, it simply reutilizes your previous selection, basically equivalent to `gv<leader>c`
| V      | <leader>ca | Ask Claude about the visual selection, without modifying it. The result appears in a float as it gets processed in the backround, including possible drafts or versions of something without changing its buffer.|
| N      | <leader>ca | Ask Claude anything, no visual selection. The answer comes up in a float. |
| N      | <leader>ca | Fast version, if you hit ca faster than the follow-up time, then the previous selection is reutilized same as `gv<leader>ca` only if you previously invoked `<leader>ca` in visual mode as your last `<leader>c...` invocation. |
| N      | <leader>ci | Insert whole new content at the cursors existing position in normal mode, or insert mode. |
| N      | <leader>cm | Change Claude model, shows you the whole catalogue advertised by the SDK, with two follow-up menus for effort level, and artificial context limiter if any, gives a preset choice of 50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k, 258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k, 500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k, 950k, 980k |
| N      | <leader>cM | Set the Claude model slug manually, including the effort level, format = slug[context]:effort -- if the context doesn't map to a real model variant (e.g. claude-opus-4-6[1m], the supplied context window is applied as a limiter to the default instead, e.g. claude-haiku-5-5[100k]:low is valid here, even if it would be invalid in the SDK, [100k] is stripped, so is :low, and it is interpreted as claude-haiku-5-5 on low reasoning with a context window limit, up to 100,000 context until auto-compaction. To limit Opus 4.6 1m to 500k that would look like claude-opus-4-6[1m][500k]:high since everything prior to the last [] pair is the modlel slug, everything after the last : is the effort level. |
| N      | <leader>cC | `:NvClaude clear` - wipe your context window, ephemeral conversation, and therefore cache. |
| N      | <leader>cn | `:NvClaude new` - create a new context window. |
| N      | <leader>cS | `:NvClaude sticky` - toggle sticky so all context windows persist. |
| N      | <leader>cs | `:NvClaude save` - take the current ephemeral window and make it persist. |
| N      | <leader>cx | `:NvClaude info` - show the current context window state in a centered float (occupancy, cache proximity, ephemeral vs persistent, etc.). |
| N      | <leader>cl | `:NvClaude list` - picker to see and resume old saved context windows (`YY:MM:DD:HH:MM:SS - <Initial Prompt...>`). |

Also drivable through the command :NvClaude which contains a completion menu.

:NvClaude login may or may not be necessary depending on whether or not the SDK can simply ride off of your installed and authenticated Claude Code credentials, otherwise it just initiated OAuth for Claude Code, and the plugin safely stores its own refresh token.

## What About Conversations?!

You can have them. In fact, it would be a bit dumb if you select something, tell Haiku to make it more ... then decide it needs to be less ... but it's a new context window so how would Haiku know what ... is let alone to make less of it?
So what are you continuing one giant conversation here with each prompt? Kind of, it depends.

### 1h/5m Cache Warming
If you have just sent a request, and it went through Claude Code, which this does, you have a 1h Cache window. If it went through the API then you have a 5m cache.
Your prompts are ephemeral and expire when cache expires, however within the cache window, and up to the context limit, any follow-up prompts will ride the same context window.
When cache expires, then the prompt ditches the prefix and you get a new context window.
You can manually clear it with `:NvClaude clear` to wipe your context window, ephemeral conversation, and therefore cache, or alternatively `<leader>cC` in normal mode.
It's rare that you will ever hit a compaction boundary, but you can compact manually too with `:NvClaude compact`
If you want to take the current ephemeral window and make it persist, you can `:NvClaude save` or `:NvClaude sticky` to have all context windows persist, and `:NvClaude new` creates a new one, alternatively `<leader>cn` for new, `<leader>cS` to toggle sticky, and `<leader>cs` to save the current context window and make it persist.
To see the current context window state, including how much it's occupying, how close to the cache limit you are, whether it's ephemeral or whether it persists, etc, do `:NvClaude info` alternatively `<leader>cx` and a centered float popup will display the context window similar to `/context` in Claude Code, along with the additional relevant info.
To see and resume old context windows that you have saved `:NvClaude list` and a picker will let you choose, `YY:MM:DD:HH:MM:SS - <Initial Prompt...>` sorted chronologically. Alternatively, `<leader>cl`

### Extra

- `:NvClaude watermarks allow` leaves watermark characters alone.
- `:NvClaude watermarks remove` removes watermark characters entirely from the output.
- `:NvClaude watermarks replace` replaces watermark characters with their nearest ASCII equivalent.

These don't have bindings, but when set to remove or replace, characters like `—` are either stripped or replaced with their ascii counterpart `-` -- it's subtle if you don't have an eye for it, easily spotted if you show the current character byte in your winbar. These would honestly not be a problem in my eyes, it's no secret that we're in the age of AI and that we're using AI, but it complicates navigation. You cannot `f-` a `—` and good luck memorizing the unicdode code points.

IMPORTANT! This does not remove those characters from your context window. A follow-up message will still operate on the output that contained the watermark characters because the cache must be preserved. This ONLY applies at the output layer.

- `:NvClaude system modify` opens the default system prompt supplied by nvim-claude to the Claude Agents SDK which you can modify temporarily for a session, but this will not persist across restarts, and can be cleared with `:NvClaude system default` -- the buffer that the system prompt opens in, will use the system prompt you write there, the moment you save; it reacts to being saved and sets the system prompt. Please note that this will bust the cache, and therefore wipe your conversation on the next message, so this is best paired with `:NvClaude sticky on` to retain the conversation.

```
You are Claude operating inside of Neovim. You have no tools at your disposal.
You are here to help the user perform edits and answer questions.

The user can invoke you several different ways, all of which will supply <blocks> </blocks>.
The following contract explains what to do with each one and what they mean.

---
<prompt type="replace"> Please fill in the missing word </prompt>
<context range="163:-8:+5">
Start of the file.

...

This is a couple of lines above the line I'm about to select, but it's really the word qute not quick.

Testing whether or not nvim-claude will understand that the ... is actually something else...

<input>The ... brown fox jumps over the lazy dog.</input>


...

End of the file
</context>
---

Your context block will contain both the actual input the user is feeding you, as well as content *around* the input. The entire file will be given to you initially, but on subsequent requests, a compact diff will be provided instead, showing what changed between the last time you were invoked and the present. If you see no <diff> </diff> block then it is the first request, or nothing changed. The conversation is mostly ephemeral and will not be saved, however so long as this context rmains within cache, which may be anywhere from 5 minutes to 1 hour, then future prompts will reutilize this context window and you will remember the message history, and can use that to provide better answers or reesolve ambiguity. You may receive a request like this as a follow-up to the first one.

---
<prompt type="ask"> Why did you choose the word qute and not quick? </prompt>
---

You will always receive a <prompt> but the type may differ and so can <input> and <context>
- "ask", "ask" with <input>, "ask" with <input> and <context>
- "replace", "replace" with <input>, "replace" with <input> and <context>
- "generate", "generate" with <input>, "generate" with <input> and <context>

Your output will be used verbatim as the result for any of these operations.
```
