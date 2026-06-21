savedcmd_arch/arm64/boot/dts/overlays/rotary-encoder.dtbo := mkdir -p arch/arm64/boot/dts/overlays/ ; aarch64-linux-gnu-gcc -E -Wp,-MMD,arch/arm64/boot/dts/overlays/.rotary-encoder.dtbo.d.pre.tmp -nostdinc -I./scripts/dtc/include-prefixes -undef -D__DTS__ -x assembler-with-cpp -o arch/arm64/boot/dts/overlays/.rotary-encoder.dtbo.dts.tmp arch/arm64/boot/dts/overlays/rotary-encoder-overlay.dts ; ./scripts/dtc/dtc -@ -H epapr -O dtb -o arch/arm64/boot/dts/overlays/rotary-encoder.dtbo -b 0 -i arch/arm64/boot/dts/overlays/ -Wno-interrupt_provider -Wno-unique_unit_address -Wno-unit_address_vs_reg -Wno-gpios_property -Wno-avoid_unnecessary_addr_size -Wno-alias_paths -Wno-graph_child_address -Wno-simple_bus_reg   -Wno-interrupts_property -Wno-label_is_string -Wno-reg_format -Wno-pci_device_bus_num -Wno-i2c_bus_reg -Wno-spi_bus_reg -Wno-avoid_default_addr_size -d arch/arm64/boot/dts/overlays/.rotary-encoder.dtbo.d.dtc.tmp arch/arm64/boot/dts/overlays/.rotary-encoder.dtbo.dts.tmp ; cat arch/arm64/boot/dts/overlays/.rotary-encoder.dtbo.d.pre.tmp arch/arm64/boot/dts/overlays/.rotary-encoder.dtbo.d.dtc.tmp > arch/arm64/boot/dts/overlays/.rotary-encoder.dtbo.d

source_arch/arm64/boot/dts/overlays/rotary-encoder.dtbo := arch/arm64/boot/dts/overlays/rotary-encoder-overlay.dts

deps_arch/arm64/boot/dts/overlays/rotary-encoder.dtbo := \

arch/arm64/boot/dts/overlays/rotary-encoder.dtbo: $(deps_arch/arm64/boot/dts/overlays/rotary-encoder.dtbo)

$(deps_arch/arm64/boot/dts/overlays/rotary-encoder.dtbo):
