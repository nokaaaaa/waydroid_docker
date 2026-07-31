#!/usr/bin/env python3
"""Relay Aiphone IPv4 discovery from Waydroid to the physical LAN.

The Android app sends a limited broadcast from a routed container. Linux does
not forward that packet between broadcast domains, so receive it at AF_PACKET
level and emit an equivalent IPv4 broadcast on the physical interface.
"""

import argparse
import socket
import struct
import threading


ETH_P_IP = 0x0800
SO_BINDTODEVICE = 25


def checksum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    words = struct.unpack(f"!{len(data) // 2}H", data)
    total = sum(words)
    total = (total & 0xFFFF) + (total >> 16)
    total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def make_ipv4_udp_packet(
    source_ip: bytes,
    destination_ip: bytes,
    source_port: int,
    destination_port: int,
    payload: bytes,
    packet_id: int,
) -> bytes:
    # A zero UDP checksum is valid for IPv4 and avoids carrying checksum-offload
    # metadata from the captured virtual-interface frame.
    udp_header = struct.pack(
        "!HHHH", source_port, destination_port, 8 + len(payload), 0
    )
    ip_header_without_checksum = struct.pack(
        "!BBHHHBBH4s4s",
        0x45,
        0,
        20 + len(udp_header) + len(payload),
        packet_id,
        0,
        64,
        socket.IPPROTO_UDP,
        0,
        source_ip,
        destination_ip,
    )
    ip_header = (
        ip_header_without_checksum[:10]
        + struct.pack("!H", checksum(ip_header_without_checksum))
        + ip_header_without_checksum[12:]
    )
    return ip_header + udp_header + payload


def parse_udp_frame(frame: bytes):
    if len(frame) < 42 or struct.unpack("!H", frame[12:14])[0] != ETH_P_IP:
        return None
    ip_offset = 14
    version_ihl = frame[ip_offset]
    if version_ihl >> 4 != 4:
        return None
    ihl = (version_ihl & 0x0F) * 4
    if ihl < 20 or len(frame) < ip_offset + ihl + 8:
        return None
    if frame[ip_offset + 9] != socket.IPPROTO_UDP:
        return None
    udp_offset = ip_offset + ihl
    source_port, destination_port, udp_length = struct.unpack(
        "!HHH", frame[udp_offset : udp_offset + 6]
    )
    if udp_length < 8 or udp_offset + udp_length > len(frame):
        return None
    return (
        frame[ip_offset + 12 : ip_offset + 16],
        frame[ip_offset + 16 : ip_offset + 20],
        source_port,
        destination_port,
        frame[udp_offset + 8 : udp_offset + udp_length],
    )


def relay_responses(args) -> None:
    receive = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
    receive.bind((args.outside, 0))
    transmit = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    transmit.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
    transmit.setsockopt(
        socket.SOL_SOCKET, SO_BINDTODEVICE, args.inside.encode() + b"\x00"
    )
    android_address = socket.inet_aton(args.source_ip)
    packet_id = 0
    while True:
        parsed = parse_udp_frame(receive.recv(65535))
        if parsed is None:
            continue
        source_address, destination_address, source_port, destination_port, payload = parsed
        if destination_port != args.response_port or destination_address != android_address:
            continue
        packet_id = (packet_id + 1) & 0xFFFF
        packet = make_ipv4_udp_packet(
            source_address,
            android_address,
            source_port,
            args.response_port,
            payload,
            packet_id,
        )
        transmit.sendto(packet, (args.source_ip, args.response_port))
        print(
            f"relayed response: {socket.inet_ntoa(source_address)}:{source_port} "
            f"-> {args.source_ip}:{args.response_port} ({len(payload)} bytes)",
            flush=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inside", default="waydroid0")
    parser.add_argument("--outside", default="wlp0s20f3")
    parser.add_argument("--source-ip", default="192.168.0.250")
    parser.add_argument("--broadcast-ip", default="192.168.0.255")
    parser.add_argument("--port", type=int, default=51711)
    parser.add_argument("--response-port", type=int, default=51712)
    args = parser.parse_args()

    receive = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
    receive.bind((args.inside, 0))

    transmit = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    transmit.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
    transmit.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    transmit.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, args.outside.encode() + b"\x00")

    source_address = socket.inet_aton(args.source_ip)
    destination_address = socket.inet_aton(args.broadcast_ip)
    packet_id = 0
    threading.Thread(target=relay_responses, args=(args,), daemon=True).start()
    print(
        f"Relaying UDP/{args.port} requests {args.inside} -> {args.outside}; "
        f"UDP/{args.response_port} responses {args.outside} -> {args.inside}",
        flush=True,
    )

    while True:
        parsed = parse_udp_frame(receive.recv(65535))
        if parsed is None:
            continue
        _, _, source_port, destination_port, payload = parsed
        if destination_port != args.port:
            continue
        packet_id = (packet_id + 1) & 0xFFFF
        packet = make_ipv4_udp_packet(
            source_address,
            destination_address,
            source_port,
            args.port,
            payload,
            packet_id,
        )
        transmit.sendto(packet, (args.broadcast_ip, args.port))
        print(
            f"relayed {len(payload)} bytes from UDP source port {source_port}",
            flush=True,
        )


if __name__ == "__main__":
    main()
