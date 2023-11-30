import 'dart:async';
import 'dart:convert';

import 'package:dart_ping/dart_ping.dart';
import 'package:flutter/material.dart';
import 'package:simple_wake_on_lan/constants.dart';
import 'dart:io';
import 'package:wake_on_lan/wake_on_lan.dart';
import 'data.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:http/http.dart' as http;

Future<String> getMacAddress(ipAddress) async {
  try {
    final response = await http.get(Uri.parse('http://$ipAddress:${AppConstants.shutdownServicePort}/details'))
        .timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          return http.Response('Timeout', 408);
        });

    debugPrint('Got response ${response.statusCode}');

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data.hardwareAddress;
    }

  } on Exception catch(e) {
    debugPrint(e.toString());
  }

  return "";
}

Stream<NetworkDevice> findDevicesInNetwork(
  String networkPrefix,
  void Function(double) progressCallback,
) {
  final controller = StreamController<NetworkDevice>();
  var progress = 0;
  const step = 25;

  /* Recursive function which pings a single device and schedules the next ping
    step ips away from the current as long as this ip is still within the subnet */
  void pingDevice(int index) async {
    final address = '$networkPrefix.$index';
    final ping = Ping(address, count: 1, timeout: AppConstants.homePingTimeout);

    // Wait for the current ping to complete
    await for (final response in ping.stream) {
      if (response.response != null && response.error == null) {
        // try to get the hostname of the device
        String host = "";
        try {
          await InternetAddress(address)
              .reverse()
              .then((value) => host = value.host);
        } on SocketException {
          host = "";
        }
        String macAddress = await getMacAddress(address);
        controller.add(NetworkDevice(ipAddress: address, hostName: host, macAddress: macAddress));
        break;
      }
    }

    // If the end of the subnet is reached, close the stream
    if (index == 254) {
      controller.close();
    }

    // Increase the progress variable and report the result to the UI
    final progressPercent = ++progress / 255;
    progressCallback(progressPercent);

    // Schedule the next ping
    if (index + step < 255) {
      pingDevice(index + step);
    }
  }

  // Start the initial pings.
  for (int i = 1; i <= step; i++) {
    pingDevice(i);
  }

  return controller.stream;
}

/// sends the magic packet to the [device] that should receive a magic wol package in order to get woken up
Stream<Message> sendWolPackage(
    {required BuildContext context, required NetworkDevice device}) async* {
  // Validate correct formatting of ip and mac addresses
  final ip = device.ipAddress;
  final mac = device.macAddress;
  final int? port = device.wolPort;
  bool invalid = false;

  if (!IPv4Address.validate(ip)) {
    yield Message(
        text: AppLocalizations.of(context)!.homeWolCardIp(ip),
        type: MsgType.error);
    invalid = true;
  }

  if (!MACAddress.validate(mac)) {
    yield Message(
        text: AppLocalizations.of(context)!.homeWolCardMac(mac),
        type: MsgType.error);
    invalid = true;
  }

  //validate port
  if (port == null || port < 0 || port > 65535) {
    String portString = port == null ? "" : port.toString();
    yield Message(
        text: AppLocalizations.of(context)!.homeWolCardPort(portString),
        type: MsgType.error);
    invalid = true;
  }

  if (invalid) {
    yield Message(
        text: AppLocalizations.of(context)!.homeWolCardInvalid,
        type: MsgType.error);
    return;
  }

  // if no error occurred: try to send wol package
  yield Message(text: AppLocalizations.of(context)!.homeWolCardValid);
  yield Message(text: AppLocalizations.of(context)!.homeWolCardSendWol);

  IPv4Address ipv4Address = IPv4Address(ip);
  MACAddress macAddress = MACAddress(mac);

  // sometimes only a broadcast works to wake a device so a broadcast is sent additionally

  final subnet = ip.substring(0, ip.lastIndexOf("."));
  final broadcast = "$subnet.255";
  IPv4Address ipv4Broadcast = IPv4Address(broadcast);

  // get localisation string beforehand to avoid using BuildContexts across async gaps
  String homeWolCardSendWolSuccess =
      AppLocalizations.of(context)!.homeWolCardSendWolSuccess(ip);
  String homeWolCardPingInfo =
      AppLocalizations.of(context)!.homeWolCardPingInfo;
  String homeWolCardPingSuccess =
      AppLocalizations.of(context)!.homeWolCardPingSuccess;
  String homeWolCardPingFail =
      AppLocalizations.of(context)!.homeWolCardPingFail;

  try {
    WakeOnLAN wol = WakeOnLAN(ipv4Address, macAddress, port: port!);
    await wol.wake(repeat: 3);
    await Future.delayed(const Duration(seconds: 1));
    WakeOnLAN wolBroadcast = WakeOnLAN(ipv4Broadcast, macAddress, port: port);
    await wolBroadcast.wake(repeat: 3);
    yield Message(text: homeWolCardSendWolSuccess, type: MsgType.check);
  } catch (e) {
    yield Message(
        text: AppLocalizations.of(context)!.homeWolCardSendWolFail(ip),
        type: MsgType.error);
  }

  await Future.delayed(const Duration(seconds: 5));

  // ping device until it is online
  yield Message(text: homeWolCardPingInfo);
  bool online = false;
  int tries = 0;
  const maxPings = 25;
  while (!online && tries < maxPings) {
    tries++;

    // BuildContext has to be used async here to get the current tries in the message
    // ignore: use_build_context_synchronously
    if (!context.mounted) return;
    yield Message(
        text: AppLocalizations.of(context)!.homeWolCardPing(tries),
        type: MsgType.ping);

    final ping = Ping(ip, count: 1, timeout: 5);

    // Wait for the current ping to complete
    await for (final response in ping.stream) {
      if (response.response != null && response.error == null) {
        online = true;
      }
    }
  }
  if (online) {
    yield Message(text: homeWolCardPingSuccess, type: MsgType.online);
  } else {
    yield Message(text: homeWolCardPingFail, type: MsgType.error);
  }
}

/// returns a list of Messages by using the sendWolPackage function
/// accumulates the messages in a list and yields the list after each message
Stream<List<Message>> sendWolAndGetMessages(
    {required BuildContext context, required NetworkDevice device}) async* {
  List<Message> messages = [];
  await for (Message message
      in sendWolPackage(context: context, device: device)) {
    // if last message is ping, replace it with the new one
    if (messages.isNotEmpty &&
        messages.last.type == MsgType.ping &&
        message.type == MsgType.ping) {
      messages.removeLast();
    }
    messages.add(message);
    yield messages;
  }
}

/// returns a list of Messages by using the sendWolPackage function
/// accumulates the messages in a list and yields the list after each message
Stream<List<Message>> sendShutdownAndGetMessages(
    {required BuildContext context, required NetworkDevice device}) async* {
  List<Message> messages = [];
  await for (Message message
  in sendShutdownRequest(context: context, device: device)) {
    messages.add(message);
    yield messages;
  }
}
//yield Message(text: homeWolCardPingSuccess, type: MsgType.online);
Stream<Message> sendShutdownRequest(
    {required BuildContext context, required NetworkDevice device}) async* {

  final ip = device.ipAddress;
  bool invalid = false;

  if (!IPv4Address.validate(ip)) {
    yield Message(
        text: AppLocalizations.of(context)!.homeWolCardIp(ip),
        type: MsgType.error);
    invalid = true;
  }

  if (invalid) {
    yield Message(
        text: AppLocalizations.of(context)!.homeWolCardInvalid,
        type: MsgType.error);
    return;
  }

  debugPrint('Sending request to $ip:${AppConstants.shutdownServicePort}');

  yield Message(
      text: AppLocalizations.of(context)!.homeShutdownProgress);

  try {
    final response = await http.get(Uri.parse('http://$ip:${AppConstants.shutdownServicePort}/shutdown'))
        .timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          return http.Response('Timeout', 408);
        });

    debugPrint('Got response ${response.statusCode}');

    if (response.statusCode == 200) {
      yield Message(
          text: AppLocalizations.of(context)!.homeShutdownSuccess,
          type: MsgType.online);
      return;
    }
  } on Exception catch(e) {
    debugPrint(e.toString());
  }

  yield Message(
      text: AppLocalizations.of(context)!.homeShutdownFailed,
      type: MsgType.error);

}

/// ping a list of devices and return their status
Future<bool> pingDevice({required String ipAddress}) async {
  final ping = Ping(ipAddress, count: 1, timeout: 3);

  // Wait for the current ping to complete
  await for (final response in ping.stream) {
    if (response.response != null && response.error == null) {
      return true;
    }
  }
  return false;
}

/// discover if shutdown service is available
Future<bool> checkShutdownService({required String ipAddress}) async {

  try {
    final response = await http.get(Uri.parse('http://$ipAddress:${AppConstants.shutdownServicePort}/status'))
        .timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          return http.Response('Timeout', 408);
        });

    debugPrint('Got response ${response.statusCode}');

    return true;

  } on Exception catch(e) {
    debugPrint(e.toString());
  }

  return false;
}

/// Playground: Test different Discover methods

// void findDevicesMDNS() async {
//   const String name = '_dartobservatory._tcp.local';
//   final MDnsClient client = MDnsClient();
//   // Start the client with default options.
//   await client.start();
//
//   // Get the PTR record for the service.
//   await for (final PtrResourceRecord ptr in client
//       .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(name))) {
//     // Use the domainName from the PTR record to get the SRV record,
//     // which will have the port and local hostname.
//     // Note that duplicate messages may come through, especially if any
//     // other mDNS queries are running elsewhere on the machine.
//     await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
//         ResourceRecordQuery.service(ptr.domainName))) {
//       // Domain name will be something like "io.flutter.example@some-iphone.local._dartobservatory._tcp.local"
//       final String bundleId =
//           ptr.domainName; //.substring(0, ptr.domainName.indexOf('@'));
//       // print('Dart observatory instance found at '
//       //     '${srv.target}:${srv.port} for "$bundleId".');
//     }
//   }
//   client.stop();
//
//   // print('Done.');
// }
