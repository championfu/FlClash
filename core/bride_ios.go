//go:build ios && cgo

package main

/*
#include <stdlib.h>
*/
import "C"

import "unsafe"

var iosEventQueue = make(chan string, 256)

// Network Extension sockets are excluded from the tunnel by the operating
// system, so Android's VpnService.protect equivalent is not required on iOS.
func protect(_ unsafe.Pointer, _ int) {}

func resolveProcess(_ unsafe.Pointer, _ int, _, _ string, _ int) string {
	return ""
}

func invokeResult(_ unsafe.Pointer, _ string) {}

func releaseObject(_ unsafe.Pointer) {}

// The Packet Tunnel DNS servers are configured through NEDNSSettings. The iOS
// build of mihomo intentionally does not expose the desktop system-DNS hooks.
func handleUpdateSystemDNS(_ []string) {}

func dispatchPlatformMessage(message Message) bool {
	data, err := (ActionResult{Method: messageMethod, Data: message}).Json()
	if err != nil {
		return true
	}
	select {
	case iosEventQueue <- string(data):
	default:
		// Network Extension memory is tightly constrained. Drop the oldest
		// burst rather than blocking proxy traffic when the UI is suspended.
	}
	return true
}

func takeCString(value *C.char) string {
	if value == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(value))
	return C.GoString(value)
}
