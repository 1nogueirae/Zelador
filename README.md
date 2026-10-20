# Zelador

Análise e manutenção leve do Windows 10/11 num único script PowerShell. Não precisa instalar nada: usa o Windows PowerShell 5.1 que já vem no sistema.

Por padrão o Zelador **só lê** e mostra um relatório. As ações (limpar caches, desligar anúncios etc.) ficam num menu à parte, e cada uma pede confirmação.

## O que ele verifica

| Área | O quê |
|---|---|
| Sistema | Versão do Windows, hardware, tempo desde o último boot |
| Discos | Espaço livre, saúde dos SSDs/HDs, TRIM |
| Espaço | Caches conhecidos (Google Drive, npm, Gradle, pip, shaders, Docker, Android, Windows Update...), as 15 maiores pastas, Downloads |
| Segurança | Defender (tempo real, assinaturas, varredura completa, histórico), firewall, UAC, arquivo hosts, proxy, Winlogon, IFEO, processos sem assinatura ou rodando de lugares estranhos |
| Inicialização | Programas que abrem com o Windows (só os ativos), tarefas agendadas e serviços de terceiros |
| Otimizações | Anúncios no Iniciar, Game DVR, Bing na busca, inicialização rápida, telemetria, apps pré-instalados comuns |
| Atualizações | Apps com versão nova no `winget` |

## Ações disponíveis (`-Acoes`)

1. Limpar caches (npm, Gradle, pip, Yarn, shaders NVIDIA/DirectX, dumps, temporários)
2. Desligar anúncios e sugestões no Iniciar
3. Desligar a gravação em segundo plano do Game Bar (os apps do Xbox continuam instalados)
4. Desligar o Bing na busca do Iniciar
5. Desligar a inicialização rápida *(admin)*
6. Atualizar todos os apps com `winget upgrade --all`

## Como usar

Clone ou baixe o repositório e dê dois cliques em `zelador.cmd`, ou rode no terminal:

```powershell
.\zelador.cmd                          # só análise
.\zelador.cmd -Acoes                   # análise + menu de ações
.\zelador.cmd -Profundo                # inclui arquivos > 1 GB no C: (demora)
.\zelador.cmd -Html relatorio.html     # salva o relatório em HTML
```

Rodar como administrador libera mais verificações e as ações marcadas com *(admin)*.

## Avisos

- As ações mexem no registro do usuário e, como admin, em algumas políticas do sistema. Leia o script antes de rodar: ele é curto de propósito.
- "Atenção" no relatório é um sinal para olhar, não uma prova de problema.

## Licença

[MIT](LICENSE)
