savedcmd_arch/arm64/boot/dts/overlays/overlay_map.dtb := gcc -E -Wp,-MMD,arch/arm64/boot/dts/overlays/.overlay_map.dtb.d.pre.tmp -nostdinc -I./scripts/dtc/include-prefixes -undef -D__DTS__ -x assembler-with-cpp -o arch/arm64/boot/dts/overlays/.overlay_map.dtb.dts.tmp arch/arm64/boot/dts/overlays/overlay_map.dts ; ./scripts/dtc/dtc -o arch/arm64/boot/dts/overlays/overlay_map.dtb -b 0 -iarch/arm64/boot/dts/overlays/ -i./scripts/dtc/include-prefixes -Wno-interrupt_provider -Wno-unique_unit_address -Wno-unit_address_vs_reg -Wno-gpios_property -Wno-avoid_unnecessary_addr_size -Wno-alias_paths -Wno-graph_child_address -Wno-simple_bus_reg   -d arch/arm64/boot/dts/overlays/.overlay_map.dtb.d.dtc.tmp arch/arm64/boot/dts/overlays/.overlay_map.dtb.dts.tmp ; cat arch/arm64/boot/dts/overlays/.overlay_map.dtb.d.pre.tmp arch/arm64/boot/dts/overlays/.overlay_map.dtb.d.dtc.tmp > arch/arm64/boot/dts/overlays/.overlay_map.dtb.d

source_arch/arm64/boot/dts/overlays/overlay_map.dtb := arch/arm64/boot/dts/overlays/overlay_map.dts

deps_arch/arm64/boot/dts/overlays/overlay_map.dtb := \

arch/arm64/boot/dts/overlays/overlay_map.dtb: $(deps_arch/arm64/boot/dts/overlays/overlay_map.dtb)

$(deps_arch/arm64/boot/dts/overlays/overlay_map.dtb):
