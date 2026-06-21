# Input Device Configuration for the ByQDtech / 全动电子 USB touch panel
# (USB VID 0483, PID 5750; kernel name "... ByQDtech 触控USB鼠标").
#
# The panel is a single-touch ABSOLUTE digitizer: it reports ABS_X (0..1024),
# ABS_Y (0..600), ABS_PRESSURE and BTN_TOUCH. BUT its kernel driver does NOT set
# INPUT_PROP_DIRECT, so Android's InputReader classifies it as a touch *pad* and
# draws an on-screen pointer (the "cursor") instead of treating taps as direct
# touches. Forcing the device type to touchScreen makes Android map the ABS range
# onto the display and deliver real touch events.
touch.deviceType = touchScreen

# The digitizer's axes track the panel orientation 1:1 with the display, so it
# should NOT be rotated with screen content.
touch.orientationAware = 0
