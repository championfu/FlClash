//go:build ios

package platform

// iOS Packet Tunnel extensions already keep their own file-descriptor budget
// and do not expose per-process socket ownership to third-party applications.
func ShouldBlockConnection() bool {
	return false
}

func QuerySocketUidFromProcFs(_, _ interface{}) int {
	return -1
}
