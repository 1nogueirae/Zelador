# Zelador

Painel de análise e manutenção do Windows 10/11, com interface própria e tema escuro. Não precisa instalar nada: é PowerShell 5.1 + WPF, que já vêm no Windows.

## Como abrir

Clone ou baixe o repositório e dê dois cliques em **`zelador.cmd`**.

Abrir como usuário comum já mostra tudo. Para mudar serviços e ajustes do sistema, use o botão **Reabrir como admin** na barra lateral.

## Páginas

| Página | O que tem |
|---|---|
| **Painel** | Nota de saúde de 0 a 100, CPU e memória ao vivo, discos com saúde e espaço livre, pontos de atenção clicáveis |
| **Armazenamento** | Caches e sobras conhecidos (lixeira, temporários, npm, pip, Gradle, shaders, Windows Update, Google Drive, Docker...) com botão Limpar, e um explorador que mede pastas e deixa descer de nível |
| **Segurança** | Defender (tempo real, assinaturas, varreduras), firewall, UAC, histórico de ameaças, sinais de sequestro (Winlogon, IFEO, proxy), arquivo hosts, processos sem assinatura. Botões para varredura rápida/completa e atualizar assinaturas |
| **Inicialização** | Liga/desliga os programas que abrem com o Windows (igual ao Gerenciador de Tarefas) e alterna serviços de terceiros entre Automático e Manual |
| **Debloat** | Ajustes com interruptor: anúncios, Game DVR, Bing na busca, extensões de arquivo, aceleração do mouse, inicialização rápida, telemetria, Recall. Remove apps pré-instalados (os do Xbox ficam de fora) |
| **Atualizações** | Lista do `winget upgrade`; marque e atualize com a saída ao vivo |
| **Bateria** | Saúde (capacidade atual x de fábrica), ciclos, carga e autonomia, via `powercfg /batteryreport` |
| **Registro de ações** | Tudo o que o Zelador mudou, com **Desfazer** para ajustes de registro e serviços |

## Como funciona

- `zelador.ps1`: a janela e a lógica da interface.
- `src/janela.xaml`: o layout e o tema.
- `src/coleta.ps1`: leitura do sistema (nada aqui altera nada).
- `src/acoes.ps1`: o que altera o sistema. Cada mudança guarda o valor anterior em `%LOCALAPPDATA%\Zelador\registro.json`, e é isso que permite desfazer.

O trabalho pesado (medir pastas, winget, Defender) roda em segundo plano para a janela não travar.

## Avisos

- Limpezas e remoção de apps não têm desfazer. O app sempre pergunta antes.
- Um ponto de atenção é um sinal para olhar, não prova de problema. Muito software livre não tem assinatura digital, por exemplo.

## Licença

[MIT](LICENSE)
