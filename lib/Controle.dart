import 'dart:async';
import 'dart:convert';
import 'package:wakelock/wakelock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import 'DiscoveryPage.dart';

class MyApp extends StatelessWidget {
  // Create a global key for navigation
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eng & Life',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
      ),
      navigatorKey: navigatorKey, // Assign the navigator key
      home: const MyHomePage(title: 'Eng & Life'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with TickerProviderStateMixin {
  bool isACK = false; // Variável global

  bool isListening = false;

  bool reenviarMensagem =
      false; // Variável de controle para reenvio de mensagem

  bool get isConnected =>
      connection != null &&
      connection!.isConnected; // Flag to indicate if device is still connected


  String _connectedDeviceName = '';

  double temperature = 25.0; // Valor da temperatura atual
  double targetTemperature = 22.0; // Valor da temperatura alvo
  double humidity = 60.0; // Valor da umidade atual
  double targetHumidity = 50.0; // Valor da umidade alvo
  TimeOfDay startTime = TimeOfDay(hour: 8, minute: 0); // Início da iluminação
  TimeOfDay endTime = TimeOfDay(hour: 18, minute: 0); // Fim da iluminação
  double luminosity = 3.0; // Intensidade luminosa selecionada (varia de 1 a 5)
  double co2Level=150.0;

  int dia = 0;
  int mes = 0;
  int ano = 0;
  int hora = 0;
  int minuto = 0;
  int segundo = 0;

  Completer<void> ackCompleter = Completer<void>();
  Uint8List? encodedMessage; // Variável para armazenar a mensagem codificada

  // Tab controller for switching between tabs
  late TabController _tabController;

  //Lista para escutar o que o ESP enviar
  final List<String> _receivedMessages = [];

  // Bluetooth state
  BluetoothState _bluetoothState = BluetoothState.UNKNOWN;

  // List of discovered devices
  List<BluetoothDevice> _devicesList = [];

  // Declare the TextEditingController
  final TextEditingController _messageTextFieldController =
      TextEditingController();

  // Connected device
  BluetoothDevice? _connectedDevice;

  // Connection with the device
  BluetoothConnection? connection;
// Declare a stream subscription for discovery events
  StreamSubscription<BluetoothDiscoveryResult>? _streamSubscription;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.teal,
        toolbarHeight: 30,
        elevation: 5,
        title: Center(
          child: Text(
            widget.title,
            textAlign: TextAlign.center, // Centralize o título
          ),
        ),
        bottom: TabBar(
          unselectedLabelColor: Colors.black45,
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.bluetooth), text: 'Bluetooth'),
            Tab(icon: Icon(Icons.settings), text: 'Configuração'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildBluetoothTab(),
          _buildA300Tab(),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    Wakelock.enable();
    // Initialize tab controller
    _tabController = TabController(length: 2, vsync: this);

    // Add a listener to the tab controller
    _tabController.addListener(() {
      // Get the current tab index
      int currentIndex = _tabController.index;

      // Check if the current tab is the Bluetooth tab
      if (currentIndex >= 0) {
        // Start discovery of devices
        _refreshList();
      }
    });

    // Get current state of Bluetooth
    FlutterBluetoothSerial.instance.state.then((state) {
      setState(() {
        _bluetoothState = state;
      });
    });

    // Listen for state changes of Bluetooth
    FlutterBluetoothSerial.instance
        .onStateChanged()
        .listen((BluetoothState state) {
      setState(() {
        _bluetoothState = state;
        if (_bluetoothState == BluetoothState.STATE_OFF) {
          // Turn off Bluetooth
          _disconnect();
          _showToast(context, 'Bluetooth desativado');
        } else if (_bluetoothState == BluetoothState.STATE_ON) {
          // Turn on Bluetooth
          _showToast(context, 'Bluetooth ativado');
          // Start discovery of devices
          //_startDiscovery();
        }
      });
    });
  }

  void _navigateToDiscoveryPage() async {
    final BluetoothDevice? selectedDevice = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) {
          return const DiscoveryPage();
        },
      ),
    );

    if (selectedDevice != null) {
      print('Discovery -> selected ' + selectedDevice.address);
    } else {
      print('Discovery -> no device selected');
    }

    _refreshList(); // Atualiza a lista de dispositivos
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Get the current tab index
    int currentIndex = _tabController.index;

    // Check if the current tab is the Bluetooth tab
    if (currentIndex == 0) {
      // Start discovery of devices
      _refreshList();
    }
  }

  @override
  void dispose() {
    // Dispose tab controller
    super.dispose();
    FocusScope.of(context).unfocus(); // Desfoca a caixa de texto

    // Dispose connection
    if (isConnected) {
      connection!.dispose();
      connection = null;
    }
    // Stop discovery
    _stopDiscovery();
    _tabController.dispose();
    _messageTextFieldController.dispose();
  }

// Method to stop discovery
  void _stopDiscovery() async {
    // Cancel the stream subscription if not null
    if (_streamSubscription != null) {
      await _streamSubscription!.cancel();
      _streamSubscription = null;
    }
  }

  // Method to connect to a device
  void _connect(BluetoothDevice device) async {
    if (connection != null) {
      // Dispose old connection
      connection!.dispose();
      connection = null;
    }

    try {
      // Connect to the device
      connection = await BluetoothConnection.toAddress(device.address);
      setState(() {
        _connectedDeviceName = device.name ?? 'Bluetooth sem nome';
        _connectedDevice = device;
      });
      _refreshList();
      _showToast(context, 'Conectado a ${device.name}');
      _receivedMessages.clear();
      Timer(const Duration(milliseconds: 1000), () async {
        //await _sendMessage("Info");
      });
      Timer(const Duration(milliseconds: 1000), () {
        goToA300Tab();
      });
      // Start listening to the device
      _startListening();
    } catch (exception) {
      // Handle exception
      _refreshList();
      _showToast(context, 'Erro ao tentar se conectar, tente novamente!');
    }
  }

  void _disconnect() async {
    // Dispose connection
    connection!.dispose();
    connection = null;

    setState(() {
      _connectedDevice = null;
    });

    //_showToast(context, 'Desconectado');

    // Change tab to Bluetooth tab
    //_tabController.animateTo(0); // Adicione esta linha
  }

  // Method to start listening to the device
  void _startListening() {
    connection!.input?.listen((Uint8List data) async {
      // Converta a lista de bytes para uma string
      final message = String.fromCharCodes(data);
      print('Mensagem chegando pelo Bluetooth: $message');

      String result = await _validateMessage(message);

      if (result.isNotEmpty && result != "") {
        String processedText = _processReceivedText(result);
        _receivedMessages.add(processedText);
      }
      setState(() {
        // Update state if needed
      });
    }, onDone: () {
      // Handle disconnection
      if (isConnected) {
        _disconnect();
      }

      _refreshList();
      _showToast(context, "Desconectado");
      _connectedDeviceName = "";
      //isCalibrating = false; // Indica o fim da calibração
      _receivedMessages.clear(); //
      Timer(const Duration(milliseconds: 1000), () {
        goToBluetooth();
      });

      //_pressCount =
          1; // Reseta contador da calibração caso desconecte no meio da calibração
    });

    setState(() {
      isListening = true;
    });
  }

  late String ultima;

  Future<bool> _sendMessage(String message) async {
    int crc = calcularCRC(message); // Calcula o CRC da mensagem

    String messageWithCRC =
        '<$message-$crc>'; // Adiciona o CRC à mensagem no formato correto
    encodedMessage = Uint8List.fromList(utf8.encode(messageWithCRC));

    if (message.isNotEmpty && message != "ACK") {
      if (connection != null) {
        // Envia a mensagem
        connection!.output.add(encodedMessage!);
        await connection!.output.allSent;
        ultima = message;
        print('Mensagem enviada: $messageWithCRC');
        _messageTextFieldController.clear(); // Limpa o texto digitado

        try {
          await ackCompleter.future.timeout(const Duration(milliseconds: 2000));
          print('Mensagem($messageWithCRC) enviada e ACK recebido');
          // Mensagem enviada com sucesso, ACK recebido
          reenviarMensagem =
              false; // Define que a próxima mensagem não precisa ser reenviada
          return true;
        } catch (erro) {
          // Timeout expirado ou erro ao aguardar o ACK
          print('Timeout ao aguardar o ACK: $erro');
        }
      } else {
        //@TODO colocar um aviso popup ou algo assim
        print('Erro: conexão não está estabelecida.');
      }
    } else if (message.isNotEmpty && (message == "ACK" || message == "NACK")) {
      // se receber se usar _sendMessage() para enviar ACK ou NACK envia
      connection!.output.add(encodedMessage!);
      await connection!.output.allSent;
      print('Mensagem enviada: $message');
    }

    if (reenviarMensagem) {
      // Verifica se a mensagem anterior precisa ser reenviada
      reenviarMensagem =
          false; // Define que a próxima mensagem não precisa ser reenviada
      return await _sendMessage(ultima); // Reenvia a mensagem anterior
    }

    return false;
  }

  int calcularCRC(String str) {
    int crc = 0;

    for (int i = 0; i < str.length; i++) {
      crc += str.codeUnitAt(i);
    }
    //print('CRC CALCULADO: $crc');
    return crc;
  }

  Future<String> _validateMessage(String message) async {
    message = message
        .trim(); // Remove espaços em branco no início e no final da mensagem
    print('Recebido para validar: $message');

    if (message.isNotEmpty &&
        message.startsWith('<') &&
        message.endsWith('>')) {
      // Remove os caracteres de formatação '<' e '>'
      String cleanedMessage = message.substring(1, message.length - 1);

      // Separa o dado e o checksum
      List<String> parts = cleanedMessage.split('-');
      String data = parts[0];

      if (data == "ACK") {
        // Tratar diretamente as mensagens de ACK
        print('Recebi o ACK e terminei o ackCompleter');
        ackCompleter.complete(); // Resolva o Completer do envio da mensagem

        print('Mensagem ACK recebida: $message');
        return data;
      }

      if (data == "NACK") {
        print('Mensagem NACK recebida: $message');
        // Tratar diretamente as mensagens de NACK
        if (ultima.isNotEmpty) {
          await _sendMessage("ACK");
          print('Reenviando mensagem anterior: $ultima');
          await _sendMessage(ultima);
        } else {
          print('Não há mensagem anterior para reenviar.');
        }
        return data;
      }

      int? receivedChecksum = int.tryParse(parts[1]);

      // Calcula o checksum do dado recebido
      int calculatedChecksum = calcularCRC(data);

      print('CRC CALCULADO: $calculatedChecksum');
      print('CRC RECEBIDO: $receivedChecksum');

      // Mensagem está ok? Passa mensagem e envia ACK sem aguardar resposta
      if (receivedChecksum != null && receivedChecksum == calculatedChecksum) {
        if (data != "ACK" && data != "") {
          // Se for válida, mas não for mensagem de confirmação
          print('Mensagem está OK: $data: enviando ACK');
          await _sendMessage("ACK");
          return data;
        }
        return data;
      } else {
        // Se a mensagem não for válida, envia NACK
        print('Mensagem com erro de CheckSum($data): enviando NACK');
        await _sendMessage("NACK");
      }
    } else {
      print('Mensagem com formato inválido: $message');
    }
    return '';
  }

  String _processReceivedText(String text) {
    print("Mensagem atual: $text");
    print("Ultima mensagem: $ultima");
    // Verifica se a mensagem recebida é igual à última mensagem enviada e a descarta, se for o caso
    if (text == ultima && text.length == ultima.length) {
      print("Mensagem duplicada. Descartando: $text");
      return "";
      //return "#######\n Mensagem ($text)duplicada! Descartada! \n#######";
    }

    final Map<String, String> codeMap = {
      "#=": "###############################",
      "Arre=": "Arremesso-------------------->",
      "Ci=": "                    Calibração Iniciada!\n "
          "\n1° Antes de continuar, certifique-se de encher o equipamento com ração e apertar o botão (Ligar Rosca) até começar a sair bastante ração!\n"
          "\n2° Tenha em mãos uma balança com precisão de pelo menos 5g\n"
          "\n3° Em seguida, coloque um pote para armazenar a primeira porção de ração, aperte o botão Calibrar e aguarde!\n",
      "Fim1=": "                   Fim da primeira porção\n ",
      "Fim2=": "                   Fim da Segunda porção\n ",
      "clc=": "",
      "Li=": "Liberando!",
      "Lib=": "",
      "Pe=": "Pese a ração, digite o peso no campo abaixo e aperte enviar.\n",
      "Fe=": "",
      "Can=": "Cancelado!",
      "Sa=": "Salvando...!",
      "So=": "Salvo com sucesso!",
      "Esp=": "Aguarde o fim!",
      "RecA=": "O peso digitado foi=",
      "RecB=": "O peso digitado foi=",
      "C2=":
          "\nRecoloque o pote para armazenar a segunda porção de ração, aperte o botão Calibrar e aguarde!\n",
      "FimC=": "Calibração Finalizada!",
      "FimA=": "Fim do arremesso!",
      "FimP=": "Fim da porção:",
      "FimR=": "Fora do periodo de Alimentação!",
      "H=": "Data e Hora",
      "Hi=": "    Configurações atuais do Equipamento\n"
          "\nHora para o Início da Alimentação",
      "Hf=": "Hora para o Fim da Alimentação",
      "Int=": "Intervalo----------------------->",
      "IntA=": "Intervalo entre cada arremesso",
      "ITemp=": "Intervalo entre cada porção",
      "IniA=": "Iniciando alimentação:",
      "IniP=": "Programa Inicializado!",
      "Por=": "Porção-------------------------->",
      "PesA=": "Liberando---------------------->",
      "QtdA=": "Cada porção será dividida em:",
      "QtdKg=": "Quantidade de ração diária:",
      "QtdP=": "Quantidade de porções diária:",
      "QtdRA=": "Quantidade de ração por arremesso:",
      "QtdRP=": "Quantidade de Ração por porções:",
      "TempA=": "Tempo de arremesso--->",
      "T=": "Temperatura do sensor:",
    };

    for (final code in codeMap.keys) {
      if (text.contains(code)) {
        final index = text.indexOf(code);
        final endIndex = text.indexOf("F\n", index);
        if (endIndex > index || endIndex < 0) {
          final value = endIndex > index
              ? text.substring(index + code.length, endIndex)
              : text.substring(index + code.length);
          String unit = "";

          if (code == "Hi=") {
            final hora = value.substring(0, value.indexOf(":"));
            final minuto = value.substring(value.indexOf(":") + 1);
            final result = "${codeMap[code]}:\n$hora:$minuto";
            print("Input text: $text");
            print("Processed text: $result");
            return result;
          } else if (code == "Hf=") {
            final hora = value.substring(0, value.indexOf(":"));
            final minuto = value.substring(value.indexOf(":") + 1);
            final result = "${codeMap[code]}:\n$hora:$minuto";
            print("Input text: $text");
            print("Processed text: $result");
            return result;
          } else if (code == "Por=") {
            final ini = value.substring(0, value.indexOf(","));
            final fim = value.substring(value.indexOf(",") + 1);
            final result = "${codeMap[code]}$ini de $fim";
            print("Input text: $text");
            print("Processed text: $result");
            return result;
          } else if (code == "Arre=") {
            final ini = value.substring(0, value.indexOf(","));
            final fim = value.substring(value.indexOf(",") + 1);
            final result = "${codeMap[code]}$ini de $fim";
            print("Input text: $text");
            print("Processed text: $result");
            return result;
          } else if (code == "H=") {
            final d = value.substring(0, value.indexOf("_"));
            final m =
                value.substring(value.indexOf("_") + 1, value.lastIndexOf("_"));
            final a =
                value.substring(value.lastIndexOf("_") + 1, value.indexOf(" "));
            final h =
                value.substring(value.indexOf(" ") + 1, value.indexOf(":"));
            final mn =
                value.substring(value.indexOf(":") + 1, value.lastIndexOf(":"));
            final s = value.substring(value.lastIndexOf(":") + 1);

            final formattedDate = "$d/$m/$a $h:$mn:$s";
            final result = "${codeMap[code]}:\n$formattedDate\n";

            setState(() {
              dia = int.tryParse(d)!;
              mes = int.tryParse(m)!;
              ano = int.tryParse(a)!;
              hora = int.tryParse(h)!;
              minuto = int.tryParse(mn)!;
              segundo = int.tryParse(s)!;
            });

            print("Input text: $text");
            print("Processed text: $result");
            return result;
          } else if (code == "QtdKg=" || code == "QtdRP=" || code == "QtdRA=") {
            unit = "g";
            final result = "${codeMap[code]}\n$value$unit";
            return result;
          } else if (code == "QtdA=") {
            unit = "arremesso(s).";
            final result = "${codeMap[code]}\n$value $unit";
            return result;
          } else if (code == "PesA=") {
            unit = "g de ração";
            final result = "${codeMap[code]}$value$unit";
            return result;
          } else if (code == "TempA=") {
            unit = "s";
            final result = "${codeMap[code]}$value$unit";
            return result;
          } else if (code == "T=") {
            unit = "°C.";
            final result = "${codeMap[code]}\n$value $unit";
            return result;
          } else if (code == "Lib=") {
            //ativa campo para digitar peso
            setState(() {
             // ativa = true;
            });
            final result = "${codeMap[code]}";
            return result;
          } else if (code == "Fe=") {
            //Desativa campo para digitar peso
            setState(() {
              //ativa = false;
            });
            final result = "${codeMap[code]}";
            return result;
          } else if (code == "Li=") {
            final result = "${codeMap[code]}";
            return result;
          } else if (code == "Can=") {
            setState(() {
              //_pressCount = 1;
              //isCalibrating = false;
              //ativa = false;
            });
            final result = "${codeMap[code]}";
            return result;
          } else if (code == "Esp=") {
            final result = "${codeMap[code]}";
            return result;
          } else if (code == "Sa=") {
            final result = "${codeMap[code]}";
            return result;
          } else if (code == "So=") {
            final result = "${codeMap[code]}";
            return result;
          } else if (code == "Pe=") {
            final result = "${codeMap[code]}";
            return result;
          } else if (code == "clc=") {
            final result = "${codeMap[code]} $value ";
            _receivedMessages.clear(); //
            return result;
          } else if (code == "FimC=") {
            final result = "${codeMap[code]} $value ";
            setState(() {
              //_pressCount = 1;
              //isCalibrating = false; // Indica o fim da calibração
            });
            //_receivedMessages.clear(); //
            return result;
          } else if (code == "Ci=") {
            //_pressCount = 2;
            final result = "${codeMap[code]} $value ";
            return result;
          } else if (code == "Fim1=") {
            //_pressCount = 3;
            final result = "${codeMap[code]} $value ";
            return result;
          } else if (code == "Fim2=") {
            //_pressCount = 1;
            final result = "${codeMap[code]} $value ";
            return result;
          } else if (code == "C2=") {
            final result = "${codeMap[code]} $value ";
            return result;
          } else if (code == "RecA=") {
            unit = "g";
            final result = "${codeMap[code]}$value$unit";
            return result;
          } else if (code == "RecB=") {
            unit = "g";
            final result = "${codeMap[code]}$value$unit";
            return result;
          } else if (code == "FimP=") {
            final result = "${codeMap[code]} $value ";
            return result;
          } else if (code == "Int=") {
            unit = "minuto(s)";
            final result = "${codeMap[code]}$value $unit";
            return result;
          } else if (code == "tempACK=") {
            final result = "${codeMap[code]}\n";
            return result;
          } else if (code == "FimR=") {
            final result = "${codeMap[code]}\n";
            return result;
          } else if (code == "FimA=") {
            final result = "${codeMap[code]}\n";
            return result;
          } else if (code == "#=") {
            final result = "${codeMap[code]}\n";
            return result;
          } else if (code == "IniA=") {
            final result = "${codeMap[code]}\n";
            return result;
          } else if (code == "IniP=") {
            final result = "${codeMap[code]}\n";
            return result;
          } else if (code == "QtdP=") {
            unit = "porções.";
            final result = "${codeMap[code]}\n$value $unit";
            return result;
          } else if (code == "ITemp=") {
            final hora = value.substring(0, value.indexOf(":"));
            final minuto =
                value.substring(value.indexOf(":") + 1, value.lastIndexOf(":"));
            final segundo = value.substring(value.lastIndexOf(":") + 1);
            final result = "${codeMap[code]}:\n$hora:$minuto:$segundo";
            print("Input text: $text");
            print("Processed text: $result");
            return result;
          } else if (code == "IntA=") {
            final minutos = value;
            final result = "${codeMap[code]}:\n$minutos minuto(s)\n";
            print("Input text: $text");
            print("Processed text: $result");
            return result;
          }
        }
      }
    }

    // Se o código não for encontrado, retorna uma mensagem no formato "%%-mensagem"
    final result = "%%-$text";
    print("Input text: $text");
    print("Processed text: $result");
    if (result == "") {
      return "Mensagem vazia";
    }
    return result;
  }

  // Method to show a toast message
  void _showToast(BuildContext context, String message) {
    final scaffold = ScaffoldMessenger.of(context);
    scaffold.showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'OK',
          onPressed: () {
            scaffold.hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  void _refreshList() async {
    final List<BluetoothDevice> devices =
        await FlutterBluetoothSerial.instance.getBondedDevices();
    setState(() {
      _devicesList = devices;
    });
  }

  void goToA300Tab() {
    _tabController.animateTo(1); // Índice 1 corresponde à aba A300
  }

  void goToBluetooth() {
    _tabController.animateTo(0); // Índice 0 corresponde à aba Bluetooth
  }

  Color getSliderColor() {
    if (luminosity == 1) {
      return Colors.cyanAccent;
    } else if (luminosity == 2) {
      return Colors.cyan;
    } else if (luminosity == 3) {
      return Colors.lightBlueAccent;
    } else if (luminosity == 4) {
      return Colors.lightBlue;
    } else {
      return Colors.blue;
    }
  }

//TODO  Preciso alterar essa parte para que mostre na lista só o equipamento da estufa
  Widget _buildBluetoothTab() {
    // Ordenar a lista de dispositivos
    _devicesList.sort((a, b) {
      final aName = a.name ?? '';
      final bName = b.name ?? '';
      return aName.compareTo(bName);
    });

    // Mostrar todos os dispositivos na lista
    final filteredDevicesList = _devicesList;

    return SingleChildScrollView(
      child: Column(
        children: <Widget>[
          const SizedBox(height: 30),
          const Text(
            'Estado do Bluetooth:',
            style: TextStyle(fontSize: 24),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'OFF ',
                style: TextStyle(fontSize: 24),
              ),
              Switch(
                value: _bluetoothState.isEnabled,
                onChanged: (bool value) {
                  future() async {
                    if (value) {
                      await FlutterBluetoothSerial.instance.requestEnable();
                    } else {
                      await FlutterBluetoothSerial.instance.requestDisable();
                    }
                  }

                  future().then((_) {
                    setState(() {});
                  });
                },
              ),
              const Text('ON ', style: TextStyle(fontSize: 24)),
            ],
          ),
          const Divider(thickness: 5, color: Colors.grey),
          const SizedBox(height: 10),
          const Text(
            'O equipamento não aparece na lista? \nClique em (Buscar Equipamento).',
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: _navigateToDiscoveryPage,
            child: const Text(
              'Buscar Equipamento',
              textScaleFactor: 1.7,
            ), // Substitua pelo nome correto da função
          ),
          const SizedBox(height: 20),
          const Divider(thickness: 5, color: Colors.grey),
          const Text('Selecione o equipamento\n que deseja configurar:',
              style: TextStyle(fontSize: 20)),
          const Divider(thickness: 2, color: Colors.grey),
          Column(
            children: filteredDevicesList.map((device) {
              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(
                    width: 6,
                    color: Colors.grey,
                  ),
                ),
                child: ListTile(
                  title: Text(device.name ?? 'Bluetooth sem nome'),
                  subtitle: Text(device.address),
                  trailing: isConnected && device == _connectedDevice
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : const Icon(Icons.circle, color: Colors.red),
                  onTap: () {
                    if (isConnected /*&& device == _connectedDevice*/) {
                      // Disconnect from device
                      _disconnect();
                    } else if (!isConnected) {
                      // Connect to device
                      _connect(device);
                    }
                  },
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: () async {
                  final List<BluetoothDevice> devices =
                      await FlutterBluetoothSerial.instance.getBondedDevices();
                  setState(() {
                    _devicesList = devices;
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Atualizar lista de equipamentos',
                    textScaleFactor: 1.5),
              ),
            ],
          ),
          const Divider(thickness: 5, color: Colors.grey),
          const SizedBox(height: 50),
        ],
      ),
    );
  }

// Method to build the A300 tab
  Widget _buildA300Tab() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.teal, // Defina a cor de fundo da aba aqui
      ),
      child: Container(
        child: SingleChildScrollView(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    children:  [
                      Card(
                        child: ListTile(
                          title: const Center(
                            child: Text(
                              'Temperatura',
                              style: TextStyle(fontSize: 18),
                            ),
                          ),
                          subtitle: Center(
                            child: Text(
                              'Atual: $temperature°C | Alvo: $targetTemperature°C',
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          // @Todo Lógica para abrir a tela de edição da temperatura alvo
                          // Aqui você pode chamar uma nova página ou exibir um diálogo de edição
                          // e atualizar o valor de targetTemperature com o valor selecionado pelo usuário
                        },
                        child: const Text('Editar Temperatura Alvo'),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Card(
                              child: ListTile(
                                title: const Center(
                                  child: Text(
                                    'Umidade',
                                    style: TextStyle(fontSize: 18),
                                  ),
                                ),
                                subtitle: Center(
                                  child: Text(
                                    'Atual: $humidity%',
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10), // Espaçamento horizontal entre os Cards
                          Expanded(
                            child: Card(
                              child: ListTile(
                                title: const Center(
                                  child: Text(
                                    'Nível de CO2',
                                    style: TextStyle(fontSize: 18),
                                  ),
                                ),
                                subtitle: Center(
                                  child: Text(
                                    'Atual: $co2Level',
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      Card(
                        child: ListTile(
                          title: const Center(
                            child: Text(
                              'Rotina da Iluminação',
                              style: TextStyle(fontSize: 18),
                            ),
                          ),
                          subtitle: Center(
                            child: Text(
                              'Início: ${startTime.format(context)} | Fim: ${endTime.format(context)}',
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          // @Todo Lógica para abrir a tela de edição da umidade alvo
                          // Aqui você pode chamar uma nova página ou exibir um diálogo de edição
                          // e atualizar o valor de targetHumidity com o valor selecionado pelo usuário
                        },
                        child: const Text('Editar Iluminação'),
                      ),
                      const SizedBox(height: 20),
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              title: const Text(
                                'Intensidade Luminosa',
                                style: TextStyle(fontSize: 18),
                              ),
                              subtitle: Text(
                                'Selecionada: ${luminosity.toInt()}',
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                            SliderTheme(
                              data: const SliderThemeData(
                                trackHeight: 14, // Altura da barra
                                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 10), // Tamanho do indicador (ponteiro)
                                overlayShape: RoundSliderOverlayShape(overlayRadius: 20), // Tamanho da área de toque
                                //trackShape: CustomTrackShape(), // Shape personalizado para a barra
                              ),
                              child: Slider(
                                value: luminosity,
                                min: 1,
                                max: 5,
                                divisions: 4,
                                activeColor: getSliderColor(),
                                onChanged: (value) {
                                  setState(() {
                                    luminosity = value;
                                  });
                                },label: '${luminosity.toInt()}',
                              ),
                            ),
                          ],
                        ),
                      ),
                      /*Container(
                        decoration: const BoxDecoration(
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(25),
                            topRight: Radius.circular(25.0),
                          ),
                          color: Colors
                              .green, // Definir a cor de fundo da AppBar como verde
                        ),
                        child: AppBar(
                          backgroundColor: Colors.transparent,
                          // Definir a cor de fundo da AppBar como transparente
                          elevation: 0,
                          // Remover sombra da AppBar
                          centerTitle: true,
                          title: Text(
                            'Mensagens recebidas do $_connectedDeviceName',
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ),*/
                      //const Divider(thickness: 2, color: Colors.grey),
                      const SizedBox(height: 2),
                      /*SizedBox(
                        height: 400,
                        child: isConnected
                            ? isCalibrating
                                ? const Center(
                                    child: Text(
                                      'Calibração em andamento!',
                                      style: TextStyle(
                                        color: Colors.green,
                                        fontSize: 20,
                                        fontFamily: 'Noto Sans',
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: _receivedMessages.length,
                                    itemBuilder: (context, index) {
                                      String processedText =
                                          _receivedMessages[index];
                                      return Text(
                                        processedText,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontFamily: 'Noto Sans',
                                        ),
                                      );
                                    },
                                  )
                            : const Center(
                                child: Text(
                                  'Equipamento Desconectado!',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 20,
                                    fontFamily: 'Noto Sans',
                                  ),
                                ),
                              ),
                      ),*/
                    ],
                  ),
                ),
                /*Padding(
                  padding: const EdgeInsets.all(1.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      SizedBox(
                        height: 70,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(50.0),
                            ),
                            backgroundColor: Colors.green,
                          ),
                          onPressed: isConnected
                              ? () async {
                                  _receivedMessages.clear();
                                  await _sendMessage("Info");
                                  // Função a ser executada ao pressionar o novo botão
                                }
                              : null,
                          child: const Icon(
                            Icons.info_outline_rounded,
                            color: Colors.white,
                            size: 60,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10), // Espaçamento entre os botões
                      SizedBox(
                        width: 250, // Defina a largura desejada aqui
                        height: 70,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(25.0),
                            ),
                            backgroundColor: Colors.green,
                          ),
                          onPressed: isConnected && !isCalibrating
                              ? () async {
                                  if (isConnected) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(builder: (context) => ConfigurationPage(connectedDeviceName: _connectedDeviceName,)),
                                    );
                                    // Verifica se a string de retorno não é nula
                                    if (calibracao != null && isConnected) {
                                      // Atualize a variável calibracao com a string retornada
                                      setState(() async {
                                        calibracao = calibracao;
                                        try {
                                          _receivedMessages.clear();
                                          await _sendMessage(calibracao);
                                        } catch (error) {
                                          // Lidar com o erro (timeout ou outro erro)
                                          print(
                                              'Erro ao enviar a mensagem calibracao: $error');
                                        }
                                      });
                                    }
                                  }
                                }
                              : null,
                          child: Text(
                            'Configurar $_connectedDeviceName',
                            textScaleFactor: 1.7,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),*/
              ],
            ), //row aqui
          ),
        ),
      ),
    );
  }

}

// Configuration page
class ConfigurationPage extends StatefulWidget {
  final String connectedDeviceName;

  const ConfigurationPage({Key? key, required this.connectedDeviceName}) : super(key: key);
  @override
  _ConfigurationPageState createState() => _ConfigurationPageState();
}

class _ConfigurationPageState extends State<ConfigurationPage> {
  TimeOfDay selectedTime = TimeOfDay.now();
  TimeOfDay selectedTimeFim = TimeOfDay.now();
  final pesoController = TextEditingController();
  String porcao = '1';
  String subdivisaoPorcoes = '1';
  String intervaloSubdivisao = '0';
  String tempoIntervalo = "1";

  int ano = 0;
  int mes = 0;
  int dia = 0;
  int hora = 0;
  int minuto = 0;
  int segundo = 0;

  int horaIni = 0;
  int minutoIni = 0;
  int horaFim = 0;
  int minutoFim = 0;
  int peso = 0;
  int porcoes = 1;
  int arremessos = 1;
  int intervalo = 1;
  bool checkboxValue =
  false; // Variável booleana para armazenar o estado do Checkbox
  String calibracao = '';

  Future<void> _selectTime() async {
    TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: selectedTime,
    );
    if (time != null) {
      setState(() {
        selectedTime = time;
      });
    }
  }

  Future<void> _selectTimeFim() async {
    TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: selectedTimeFim,
    );
    if (time != null) {
      setState(() {
        selectedTimeFim = time;
      });
    }
  }

  void _getDateTime() {
    DateTime now = DateTime.now();
    setState(() {
      ano = now.year;
      mes = now.month;
      dia = now.day;
      hora = now.hour;
      minuto = now.minute;
      segundo = now.second;
    });
  }

  @override
  void dispose() {
    pesoController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _getDateTime();

    // Configura um timer para atualizar a hora a cada segundo
    Timer.periodic(const Duration(seconds: 1), (_) {
      _getDateTime();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: Text('Configurar ${widget.connectedDeviceName}'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Column(
                children: <Widget>[
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: TextField(
                        autofocus: true,
                        style: const TextStyle(fontSize: 16),
                        readOnly: true,
                        onTap: _selectTime,
                        controller: TextEditingController(
                          text:
                          '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}',
                        ),
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Hora para Ligar Iluminação',
                          labelStyle: TextStyle(fontSize: 20),
                          hintText: 'Informe a hora de início',
                          hintStyle: TextStyle(fontSize: 16),
                          prefixIcon: Icon(Icons.access_time, size: 24),
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: TextField(
                        style: const TextStyle(fontSize: 16),
                        readOnly: true,
                        onTap: _selectTimeFim,
                        controller: TextEditingController(
                          text:
                          '${selectedTimeFim.hour.toString().padLeft(2, '0')}:${selectedTimeFim.minute.toString().padLeft(2, '0')}',
                        ),
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Hora para Desligar Iluminação',
                          labelStyle: TextStyle(fontSize: 20),
                          hintText: 'Informe a hora de término',
                          hintStyle: TextStyle(fontSize: 16),
                          prefixIcon:
                          Icon(Icons.access_time_filled_outlined, size: 24),
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: TextField(
                        autofocus: true,
                        style: const TextStyle(fontSize: 16),
                        controller: pesoController,
                        keyboardType: TextInputType.number,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Peso diário de ração em gramas',
                          labelStyle: TextStyle(fontSize: 17),
                          hintText: 'Informe o peso',
                          hintStyle: TextStyle(fontSize: 16),
                          prefixIcon: Icon(Icons.scale_outlined, size: 24),
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: TextField(
                        style: const TextStyle(fontSize: 16),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                          isDense: true,
                          border: OutlineInputBorder(),
                          labelStyle: TextStyle(fontSize: 20),
                          hintStyle: TextStyle(fontSize: 16),
                          labelText: 'Dividir em quantas porções?',
                          suffixIcon: Icon(Icons.arrow_drop_down, size: 24),
                          prefixIcon:
                          Icon(Icons.format_list_numbered, size: 24),
                        ),
                        controller: TextEditingController(text: porcao),
                        readOnly: true,
                        onTap: () {
                          showDialog(
                            context: context,
                            builder: (BuildContext context) {
                              return AlertDialog(
                                title: const Text('Selecione o número de porções'),
                                content: DropdownButton<String>(
                                  value: porcao,
                                  onChanged: (String? newValue) {
                                    setState(() {
                                      porcao = newValue ?? '';
                                      porcoes = newValue != null
                                          ? int.parse(newValue)
                                          : 1;
                                      Navigator.of(context).pop();
                                    });
                                  },
                                  items:
                                  List<DropdownMenuItem<String>>.generate(
                                      30, (index) {
                                    int value = index + 1;
                                    return DropdownMenuItem<String>(
                                      value: value.toString(),
                                      child: Text(value.toString()),
                                    );
                                  }).toList(),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: TextField(
                        style: const TextStyle(fontSize: 16),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                          labelText: 'Deseja subdividir cada porção?',
                          suffixIcon: Icon(Icons.arrow_drop_down, size: 24),
                          border: OutlineInputBorder(),
                          labelStyle: TextStyle(fontSize: 20),
                          hintStyle: TextStyle(fontSize: 16),
                          prefixIcon:
                          Icon(Icons.format_list_bulleted, size: 24),
                        ),
                        controller:
                        TextEditingController(text: subdivisaoPorcoes),
                        readOnly: true,
                        onTap: () {
                          showDialog(
                            context: context,
                            builder: (BuildContext context) {
                              return AlertDialog(
                                title: const Text(
                                    'Selecione em quantas vezes subdividir'),
                                content: DropdownButton<String>(
                                  value: subdivisaoPorcoes,
                                  onChanged: (String? newValue) {
                                    setState(() {
                                      subdivisaoPorcoes = newValue ?? '';
                                      arremessos = int.parse(newValue ?? '1');
                                      Navigator.of(context).pop();
                                    });
                                  },
                                  items:
                                  List<DropdownMenuItem<String>>.generate(5,
                                          (index) {
                                        int value = index + 1;
                                        return DropdownMenuItem<String>(
                                          value: value.toString(),
                                          child: Text(value.toString()),
                                        );
                                      }).toList(),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: TextField(
                        style: const TextStyle(fontSize: 16),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                          labelText: 'Intervalo entre subdivisões(minutos)?',
                          suffixIcon: Icon(Icons.arrow_drop_down, size: 24),
                          border: OutlineInputBorder(),
                          labelStyle: TextStyle(fontSize: 20),
                          hintStyle: TextStyle(fontSize: 16),
                          prefixIcon: Icon(Icons.more_time, size: 24),
                        ),
                        controller: TextEditingController(
                            text: tempoIntervalo.toString()),
                        readOnly: true,
                        onTap: () {
                          if (arremessos > 1) {
                            showDialog(
                              context: context,
                              builder: (BuildContext context) {
                                return AlertDialog(
                                  title:
                                  const Text('Selecione o intervalo em minutos'),
                                  content: DropdownButton<String>(
                                    value: tempoIntervalo.toString(),
                                    onChanged: (String? newValue) {
                                      setState(() {
                                        tempoIntervalo = newValue ?? '';
                                        intervalo = int.parse(newValue ?? '1');
                                        Navigator.of(context).pop();
                                      });
                                    },
                                    items:
                                    List<DropdownMenuItem<String>>.generate(
                                        5, (index) {
                                      int value = index + 1;
                                      return DropdownMenuItem<String>(
                                        value: value.toString(),
                                        child: Text(value.toString()),
                                      );
                                    }).toList(),
                                  ),
                                );
                              },
                            );
                          }
                        },
                      ),
                    ),
                  ),
                  Text(" $dia/$mes/$ano "),
                  Text("$hora:$minuto:$segundo"),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25.0),
                      ),
                      backgroundColor: Colors.green,
                      minimumSize: const Size(100, 50),
                    ),
                    child: const Text('Cancelar', textScaleFactor: 1.7),
                    onPressed: () {
                      Navigator.pop(context);
                    },
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25.0),
                      ),
                      backgroundColor: Colors.green,
                      minimumSize: const Size(100, 50),
                    ),
                    child: const Text('Salvar', textScaleFactor: 1.7),
                    onPressed: () {
                      peso = int.tryParse(pesoController.text) ?? 0;
                      horaIni = selectedTime.hour;
                      minutoIni = selectedTime.minute;
                      horaFim = selectedTimeFim.hour;
                      minutoFim = selectedTimeFim.minute;

                      if (arremessos <= 1) {
                        setState(() {
                          intervalo = 0;
                        });
                      }

                      calibracao =
                      'S,$horaIni,$minutoIni,$horaFim,$minutoFim,$peso,$porcoes,$arremessos,$intervalo,'
                          '$ano,$mes,$dia,$hora,$minuto,$segundo,F';

                      Navigator.pop(context, calibracao);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}