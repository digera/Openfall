package main

// Regenerates sfx/*.odin Live-export files from the Wirebang graphs in patches.odin.
//
//   odin run tools/gen_sfx -collection:wb=C:\Users\lusr\wirebang-odin

import "core:fmt"
import "core:os"
import wb "wb:wirebang"

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
		path := fmt.tprintf("sfx/%s.odin", entry.id)
		if err := os.write_entire_file(path, transmute([]u8)src); err != nil {
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
