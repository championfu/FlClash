//go:build ios && cgo

package tun

import (
	"net"
	"net/netip"
	"strings"

	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// Start attaches mihomo's userspace stack to the utun descriptor owned by the
// Network Extension. Routing itself is configured by PacketTunnelProvider.
func Start(fd int, stack string, address, dns string) *sing_tun.Listener {
	var prefix4 []netip.Prefix
	var prefix6 []netip.Prefix
	tunStack, ok := constant.StackTypeMapping[strings.ToLower(stack)]
	if !ok {
		tunStack = constant.TunMixed
	}
	for _, value := range strings.Split(address, ",") {
		prefix, err := netip.ParsePrefix(strings.TrimSpace(value))
		if err != nil {
			log.Errorln("TUN: %v", err)
			return nil
		}
		if prefix.Addr().Is4() {
			prefix4 = append(prefix4, prefix)
		} else {
			prefix6 = append(prefix6, prefix)
		}
	}

	var dnsHijack []string
	for _, value := range strings.Split(dns, ",") {
		value = strings.TrimSpace(value)
		if value != "" {
			dnsHijack = append(dnsHijack, net.JoinHostPort(value, "53"))
		}
	}

	listener, err := sing_tun.New(LC.Tun{
		Enable:              true,
		Device:              "FlClash",
		Stack:               tunStack,
		DNSHijack:           dnsHijack,
		AutoRoute:           false,
		AutoDetectInterface: false,
		Inet4Address:        prefix4,
		Inet6Address:        prefix6,
		MTU:                 9000,
		FileDescriptor:      fd,
	}, tunnel.Tunnel)
	if err != nil {
		log.Errorln("TUN: %v", err)
		return nil
	}
	return listener
}
