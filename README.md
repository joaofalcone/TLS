# TLS

Script de instalação/configuração TLS para PDV Linux (`TLS.sh`) e Windows (`TLS.ps1`).

Tudo no terminal, sem janelas e sem login:

```
1 - Cadastrar TLS   (pede o token, monta o ambiente TLS e testa)
2 - Instalar GSurf  (Windows: requisitos + serviço "sitef" + certificado;
                     Linux: /gsurf/instalador + libssl.service) e testa
3 - Testar TLS      (monta o ambiente TLS com o token do banco e testa)
4 - Testar GSurf    (monta o ambiente GSurf e testa)
0 - Sair
```

Número ou setas destacam a opção; Enter confirma. Depois de cada teste (ex.: TLS):

```
1 - Mudar para GSurf          (testa na hora)
2 - Voltar para o menu inicial
3 - Deixar como TLS e sair
```

Ao mudar: se o teste passar, "PDV em modo de comunicação GSurf. Testes realizados com sucesso.";
se falhar, mostra onde falhou e a dica para corrigir, e volta sozinho para o modo que estava funcionando.
Em seguida: `1 - Voltar para o menu principal` / `2 - Sair [ou pressione Esc]`.

Windows: o Instalar GSurf usa `C:\tef\VPN RSA Integrador - Hospedado`; se a pasta não existir, baixa
`gsurf/VPN-RSA-Integrador-Hospedado.exe` deste repositório, confere o SHA-256 e extrai em silêncio.
Linux: o PDV já traz o instalador em `/gsurf` (ISO); o script só roda os comandos.

Falha antes do teste (ou Ctrl+C) desfaz o que foi gravado. O log fica sempre em `InstalaTLS.log`
(Linux: pasta do script; Windows: `C:\checkout`).

## Execução direta pelo GitHub

No PDV Linux:

```bash
sudo bash -c 'cd /tmp && (curl -fsSLo TLS.sh https://raw.githubusercontent.com/joaofalcone/TLS/main/TLS.sh || wget -qO TLS.sh https://raw.githubusercontent.com/joaofalcone/TLS/main/TLS.sh) && chmod +x TLS.sh && ./TLS.sh'
```

## Alternativa baixando antes de executar

```bash
curl -fsSLO https://raw.githubusercontent.com/joaofalcone/TLS/main/TLS.sh
chmod +x TLS.sh
sudo ./TLS.sh
```

## PDV Windows

Mais rápido: **Win+R** (Executar), cole e Enter (o script se reabre como administrador e em 32-bit; confirme o aviso do Windows):

```
powershell -NoP -EP Bypass -C "[Net.ServicePointManager]::SecurityProtocol=3072;(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/joaofalcone/TLS/main/TLS.ps1','C:\Users\Public\TLS.ps1');&'C:\Users\Public\TLS.ps1'"
```

Atalho Ctrl+F2 (AutoHotkey v2) que abre o Executar e digita o comando:

```autohotkey
^F2::
{
    Send("#r")
    if !WinWaitActive("ahk_class #32770", , 3)
        return
    SendText("powershell -NoP -EP Bypass -C `"[Net.ServicePointManager]::SecurityProtocol=3072;(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/joaofalcone/TLS/main/TLS.ps1','C:\Users\Public\TLS.ps1');&'C:\Users\Public\TLS.ps1'`"")
    Send("{Enter}")
}
```

Ou no PowerShell do PDV:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=3072;New-Item -ItemType Directory -Force C:\TLS | Out-Null;(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/joaofalcone/TLS/main/TLS.ps1','C:\TLS\TLS.ps1');& 'C:\TLS\TLS.ps1'"
```

Ou, com o arquivo já copiado para o PDV:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\TLS\TLS.ps1"
```

O teste exige o caixa fechado. Modo TLS = `C:\checkout\CONFITLS.INI` presente; GSurf = ausente.
