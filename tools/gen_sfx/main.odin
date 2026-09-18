package main

// Regenerates Wirebang Live-export scripts into sfx/. Playback caches PCM at
// engine init; this tool only writes the graphs as Odin.
//
//   odin run tools/gen_sfx -collection:wb=C:\Users\lusr\wirebang-odin

import "core:fmt"
import "core:os"
import "core:strings"
import wb "wb:wirebang"

SUBMIT_MARKER :: "@(private=\"file\")\nMAX_PLAYING :: 8"

main :: proc() {
	os.make_directory("sfx")

	ok := true
	for entry in LIBRARY {
		p := entry.make()
		defer wb.destroy_patch(&p)
		if !wb.is_patch(p) {
			fmt.eprintf("invalid patch %s\n", entry.id)
			ok = false
			continue
		}

		src := wb.generate_code(p, {package_name = "sfx"})
		defer delete(src)
		body, stripped := strip_submit_helper(src)
		if !stripped {
			fmt.eprintf("could not share submit_pcm in %s\n", entry.id)
			ok = false
			continue
		}

		path := fmt.tprintf("sfx/%s.odin", entry.id)
		if err := os.write_entire_file(path, transmute([]u8)body); err != nil {
			fmt.eprintf("failed to write %s\n", path)
			ok = false
			continue
		}
		fmt.println(path)
	}
	if !ok {
		os.exit(1)
	}
}

// Each Live export ships its own playback pool. The game uses one shared
// submit_pcm so init can capture PCM once and every later play is a buffer copy.
@(private)
strip_submit_helper :: proc(src: string) -> (out: string, ok: bool) {
	i := strings.last_index(src, SUBMIT_MARKER)
	if i < 0 {
		return src, false
	}
	return fmt.tprintf("%s\n", strings.trim_right_space(src[:i])), true
}
