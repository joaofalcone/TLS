<#
  InstalaTLS - PDV Windows (Checkout.exe + CliSiTef32I.dll)
  Mesmo fluxo do TLS.sh do PDV Linux, tudo no console (sem login):
    menu 1 Cadastrar TLS | 2 Instalar GSurf | 3 Testar TLS | 4 Testar GSurf
    cada opcao monta o ambiente (snapshot -> grava pdvtls/CONFITLS.INI ou
    tira o INI) e faz o teste real (funcao 110 da CliSiTef); falha antes do
    teste = rollback. Depois do teste: 1 Mudar de modo (testa na hora) |
    2 Voltar ao menu | 3 Deixar como está e sair. O log fica sempre em C:\checkout\InstalaTLS.log.

  Diferencas do Linux (o PDV Windows funciona de outro jeito):
    - Modo TLS = CONFITLS.INI presente em C:\checkout; GSurf = ausente
      (nao ha flag habilita_tef_confiTLS nem pdv_out.db).
    - Nao ha servico socket: o teste chama a CliSiTef32I.dll direto, num
      processo PowerShell 32-bit novo a cada teste (a DLL rele o INI).
    - MySQL pela LIBMYSQL*.DLL do proprio checkout (nada a instalar).
    - Usuario/senha do banco: X:\Checksup\Checksup.ini (qualquer unidade).
    - Caixa: IntegracaoDB.ini (linha 6). CNPJ/numero Fiserv: pdvctr.dbf.

  Compativel com PowerShell 2.0 (Windows 7). Exige administrador e roda em
  32-bit (a CliSiTef e 32-bit); o proprio script se reabre assim.
  O teste exige o caixa fechado (Checkout.exe fora de execucao).
#>

# +--------------------------------------------------------------------------+
# | INSTALATLS - PDV WINDOWS (VISÃO GERAL)
# | O que faz: Configura e testa o TEF do caixa em TLS (Fiserv) ou GSurf, e
# |            instala a GSurf. Menu: 1 Cadastrar TLS, 2 Instalar GSurf, 3
# |            Testar TLS, 4 Testar GSurf.
# | Por quê:   Substitui passos manuais por um roteiro único, rápido e
# |            seguro: tudo que é mudado pode ser desfeito, e nada é
# |            executado sem conferência.
# +--------------------------------------------------------------------------+
# +--------------------------------------------------------------------------+
# | OPÇÕES DE ABERTURA DO SCRIPT
# | O que faz: Lista as opções que o script aceita ao ser aberto. O operador
# |            não usa nenhuma: elas servem para o próprio script se reabrir
# |            em modo de teste ou de requisitos.
# | Por quê:   O teste da CliSiTef e o verificador da GSurf precisam rodar
# |            num processo separado; essas opções dizem a esse processo o
# |            que fazer.
# +--------------------------------------------------------------------------+
param(
    [switch]$Teste,
    [string]$Modo = '',
    [string]$IpSiTef = '',
    [string]$IdLoja = '',
    [string]$IdTerm = '',
    [string]$Parms = '',
    [string]$Status = '',
    [string]$Cancelar = '',
    [int]$PctIni = 5,
    [int]$PctMax = 85,
    [int]$TimeoutSeg = 120,
    [string]$CheckoutDir = 'C:\checkout',
    [string]$ChecksupIni = '',
    [string]$Requisitos = '',
    [switch]$Auto,
    [string]$Cred = '',
    [string]$Certificado = '',
    [string]$CredArq = ''
)

$ErrorActionPreference = 'Stop'
$script:SelfPath = $MyInvocation.MyCommand.Path
$CheckoutDir = $CheckoutDir.TrimEnd('\')

# =========================================================
# CONSTANTES
# =========================================================

$CNPJ_SH_FIX   = '03082643000110'
$OPERADOR      = '999 HIPCOM'
$TLS_TABLE     = 'pdvtls'
$TLS_COL_CAIXA = 'tlscaixa'
$TLS_COL_TOKEN = 'tlstoken'
$TLS_LOJA      = 0                      # igual ao Linux (tlsloja=0)
$URL_TLS       = 'tls-prod.fiservapp.com'
$TOKEN_REGEX   = '^[0-9]{4}(-[0-9]{4}){3}$'
$AUTO_ITER     = 200000                 # PBKDF2 do PIN (igual ao -iter do openssl)

$CONFITLS_INI     = Join-Path $CheckoutDir 'CONFITLS.INI'
$CONFITLS_BKP_INI = Join-Path $CheckoutDir 'CONFITLS_BKP.INI'
$SITEF_DLL        = Join-Path $CheckoutDir 'CliSiTef32I.dll'
$INTEGRACAO_INI   = Join-Path $CheckoutDir 'IntegracaoDB.ini'
$PDVCTR_DBF       = Join-Path $CheckoutDir 'pdvctr.dbf'
$FINAL_LOG_FILE   = Join-Path $CheckoutDir 'InstalaTLS.log'
# Equivalente ao /opt/checkout/clisitef/NaoExcluirControleCliSiTef do Linux.
# No Windows fica em C:\CliSiTef e so existe depois da 1a instalacao do TLS.
# Nunca apagar C:\CliSiTef\ChavesCliSiTef (chaves do pinpad).
$CTRL_CANDIDATOS  = @('C:\CliSiTef\NaoExcluirControleCliSiTef')

# =========================================================
# NATIVO (C# 2.0 - compila no PowerShell 2.0)
# =========================================================

$script:FonteNativa = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class TlsNat
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryExW(string caminho, IntPtr reservado, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr modulo, string nome);

    public static IntPtr Carregar(string caminho)
    {
        // LOAD_WITH_ALTERED_SEARCH_PATH: dependencias saem da pasta da DLL
        IntPtr h = LoadLibraryExW(caminho, IntPtr.Zero, 0x00000008);
        if (h == IntPtr.Zero)
            throw new Exception("Nao foi possivel carregar " + caminho + " (erro " + Marshal.GetLastWin32Error() + ")");
        return h;
    }

    public static Delegate Funcao(IntPtr modulo, string nome, Type tipo)
    {
        IntPtr p = GetProcAddress(modulo, nome);
        if (p == IntPtr.Zero) throw new Exception("Funcao " + nome + " ausente na DLL");
        return Marshal.GetDelegateForFunctionPointer(p, tipo);
    }

    // Sair na hora: o fim normal do processo descarrega as DLLs nativas
    // (MySQL), o que às vezes demora e parece travado. Encerrar direto pula isso.
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern bool TerminateProcess(IntPtr processo, uint codigo);
    public static void Encerrar(int codigo) { TerminateProcess(GetCurrentProcess(), (uint)codigo); }

    // Clique no X da janela (2), logoff (5) ou desligamento (6): fecha na hora.
    public delegate bool TratadorConsole(int tipo);
    static TratadorConsole tratador;
    [DllImport("kernel32.dll")]
    static extern bool SetConsoleCtrlHandler(TratadorConsole t, bool adicionar);
    public static void VigiarFechamento()
    {
        if (tratador != null) return;
        tratador = delegate(int tipo) { if (tipo == 2 || tipo == 5 || tipo == 6) Encerrar(1); return false; };
        SetConsoleCtrlHandler(tratador, true);
    }
}

public class TlsMyDb
{
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate IntPtr FnPtr(IntPtr a);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void FnVoid(IntPtr a);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate ulong FnU64(IntPtr a);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int FnOpt(IntPtr m, int opcao, ref uint valor);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    public delegate IntPtr FnConn(IntPtr m, string host, string user, string pass, string db, uint port, string sock, uint flags);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    public delegate int FnQuery(IntPtr m, string sql);

    FnPtr init, storeResult, fetchRow, error;
    FnVoid freeResult, close;
    FnU64 affected;
    FnOpt options;
    FnConn connect;
    FnQuery query;
    IntPtr conn = IntPtr.Zero;

    public TlsMyDb(string dll)
    {
        IntPtr h = TlsNat.Carregar(dll);
        init        = (FnPtr)TlsNat.Funcao(h, "mysql_init", typeof(FnPtr));
        storeResult = (FnPtr)TlsNat.Funcao(h, "mysql_store_result", typeof(FnPtr));
        fetchRow    = (FnPtr)TlsNat.Funcao(h, "mysql_fetch_row", typeof(FnPtr));
        error       = (FnPtr)TlsNat.Funcao(h, "mysql_error", typeof(FnPtr));
        freeResult  = (FnVoid)TlsNat.Funcao(h, "mysql_free_result", typeof(FnVoid));
        close       = (FnVoid)TlsNat.Funcao(h, "mysql_close", typeof(FnVoid));
        affected    = (FnU64)TlsNat.Funcao(h, "mysql_affected_rows", typeof(FnU64));
        options     = (FnOpt)TlsNat.Funcao(h, "mysql_options", typeof(FnOpt));
        connect     = (FnConn)TlsNat.Funcao(h, "mysql_real_connect", typeof(FnConn));
        query       = (FnQuery)TlsNat.Funcao(h, "mysql_query", typeof(FnQuery));
    }

    public void Conectar(string host, uint port, string user, string pass, string db)
    {
        Fechar();
        IntPtr m = init(IntPtr.Zero);
        if (m == IntPtr.Zero) throw new Exception("mysql_init falhou");
        uint t = 5;
        options(m, 0, ref t); // MYSQL_OPT_CONNECT_TIMEOUT
        if (connect(m, host, user, pass, db, port, null, 0) == IntPtr.Zero)
        {
            string e = Marshal.PtrToStringAnsi(error(m));
            close(m);
            throw new Exception(e);
        }
        conn = m;
    }

    void Consultar(string sql)
    {
        if (conn == IntPtr.Zero) throw new Exception("sem conexao com o MySQL");
        if (query(conn, sql) != 0) throw new Exception(Marshal.PtrToStringAnsi(error(conn)));
    }

    public long Executar(string sql)
    {
        Consultar(sql);
        long n = (long)affected(conn);
        IntPtr r = storeResult(conn);
        if (r != IntPtr.Zero) freeResult(r);
        return n;
    }

    public string Escalar(string sql)
    {
        Consultar(sql);
        IntPtr r = storeResult(conn);
        if (r == IntPtr.Zero) return null;
        string v = null;
        IntPtr row = fetchRow(r);
        if (row != IntPtr.Zero)
        {
            IntPtr c = Marshal.ReadIntPtr(row);
            if (c != IntPtr.Zero) v = Marshal.PtrToStringAnsi(c);
        }
        freeResult(r);
        return v;
    }

    public void Fechar()
    {
        if (conn != IntPtr.Zero) { close(conn); conn = IntPtr.Zero; }
    }
}

public class TlsSiTef
{
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    public delegate int FnCfg(string ip, string loja, string terminal, short reservado, string parametros);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    public delegate int FnIni(int funcao, string valor, string cupom, string data, string hora, string operador, string paramAdic);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int FnCont(ref int comando, ref int tipoCampo, ref short tamMinimo, ref short tamMaximo, [In, Out] byte[] buffer, int tamBuffer, int continua);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    public delegate void FnFin(short confirma, string cupom, string data, string hora, string paramAdic);

    FnCfg cfg; FnIni ini; FnCont cont; FnFin fin;
    public int Comando;
    public int TipoCampo;
    public short TamMinimo;
    public short TamMaximo;
    public byte[] Buffer = new byte[20000];

    public TlsSiTef(string dll)
    {
        IntPtr h = TlsNat.Carregar(dll);
        cfg  = (FnCfg)TlsNat.Funcao(h, "ConfiguraIntSiTefInterativoEx", typeof(FnCfg));
        ini  = (FnIni)TlsNat.Funcao(h, "IniciaFuncaoSiTefInterativo", typeof(FnIni));
        cont = (FnCont)TlsNat.Funcao(h, "ContinuaFuncaoSiTefInterativo", typeof(FnCont));
        fin  = (FnFin)TlsNat.Funcao(h, "FinalizaFuncaoSiTefInterativo", typeof(FnFin));
    }

    public int Configurar(string ip, string loja, string terminal, string parametros)
    {
        return cfg(ip, loja, terminal, 0, parametros);
    }

    public int Iniciar(int funcao, string valor, string cupom, string data, string hora, string operador, string paramAdic)
    {
        Comando = 0; TipoCampo = 0; TamMinimo = 0; TamMaximo = 0;
        return ini(funcao, valor, cupom, data, hora, operador, paramAdic);
    }

    public int Continuar(string resposta, int continua)
    {
        Array.Clear(Buffer, 0, Buffer.Length);
        if (resposta != null)
        {
            byte[] b = Encoding.Default.GetBytes(resposta);
            Array.Copy(b, Buffer, Math.Min(b.Length, Buffer.Length - 1));
        }
        return cont(ref Comando, ref TipoCampo, ref TamMinimo, ref TamMaximo, Buffer, Buffer.Length, continua);
    }

    public string Texto()
    {
        int n = Array.IndexOf(Buffer, (byte)0);
        if (n < 0) n = Buffer.Length;
        return Encoding.Default.GetString(Buffer, 0, n);
    }

    public void Finalizar(short confirma, string cupom, string data, string hora)
    {
        fin(confirma, cupom, data, hora, "");
    }
}

public static class TlsTecla
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sec, uint c, uint f, IntPtr t);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct KEY { [FieldOffset(0)] public int down; [FieldOffset(4)] public short rep; [FieldOffset(6)] public short vk; [FieldOffset(8)] public short sc; [FieldOffset(10)] public char ch; [FieldOffset(12)] public int st; }
    [StructLayout(LayoutKind.Explicit)]
    struct REC { [FieldOffset(0)] public short type; [FieldOffset(4)] public KEY k; }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteConsoleInputW(IntPtr h, REC[] r, int n, out int w);
    public static void Enter()
    {
        IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        REC[] r = new REC[2];
        for (int i = 0; i < 2; i++) { r[i].type = 1; r[i].k.down = (i == 0) ? 1 : 0; r[i].k.rep = 1; r[i].k.vk = 0x0D; r[i].k.ch = '\r'; }
        int w;
        WriteConsoleInputW(h, r, 2, out w);
        CloseHandle(h);
    }
    public static void Digitar(string s)
    {
        IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        REC[] r = new REC[s.Length * 2];
        for (int i = 0; i < s.Length; i++)
            for (int j = 0; j < 2; j++) { REC x = new REC(); x.type = 1; x.k.down = (j == 0) ? 1 : 0; x.k.rep = 1; x.k.ch = s[i]; r[i * 2 + j] = x; }
        int w;
        WriteConsoleInputW(h, r, r.Length, out w);
        CloseHandle(h);
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool ReadConsoleOutputCharacterW(IntPtr h, System.Text.StringBuilder sb, int len, int coord, out int lido);
    public static string Tela(int linhas, int larg)
    {
        IntPtr h = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        System.Text.StringBuilder tudo = new System.Text.StringBuilder();
        for (int y = 0; y < linhas; y++)
        {
            System.Text.StringBuilder sb = new System.Text.StringBuilder(larg + 1); sb.Length = larg; int l;
            if (ReadConsoleOutputCharacterW(h, sb, larg, y << 16, out l)) tudo.AppendLine(sb.ToString(0, Math.Min(l, sb.Length)).TrimEnd());
        }
        CloseHandle(h);
        return tudo.ToString();
    }
}
'@

# ACL "só Administradores e SYSTEM" (sem herança), dono Administradores:
# o mesmo usuário fora do modo elevado (ou outro usuário) não grava nem troca nada dentro.
# (Activator/cast em vez de New-Object: o 1o New-Object do processo custa ~100 ms.)
# +--------------------------------------------------------------------------+
# | PERMISSÃO DA PASTA PROTEGIDA
# | O que faz: Monta a regra de acesso que deixa só administradores e o
# |            sistema mexerem numa pasta.
# | Por quê:   Arquivos que o script usa como administrador não podem ficar
# |            onde um usuário comum consiga trocá-los.
# +--------------------------------------------------------------------------+
function New-AclSegura {
    $sec = [Activator]::CreateInstance([Security.AccessControl.DirectorySecurity])
    $sec.SetAccessRuleProtection($true, $false)
    $adm = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $her = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @($adm, [Security.Principal.SecurityIdentifier]'S-1-5-18')) {
        $sec.AddAccessRule([Activator]::CreateInstance([Security.AccessControl.FileSystemAccessRule], @($sid, [Security.AccessControl.FileSystemRights]::FullControl, $her, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
    }
    $sec.SetOwner($adm)
    return $sec
}

# Pasta protegida do processo elevado (cache da DLL + temporários da execução).
# Fica em ProgramData (pelo caminho do sistema, não por variável de ambiente, que o
# usuário controla) e só vale se for nossa: não é junção e o dono é Administradores/SYSTEM
# (usuário comum consegue criar pasta ali, mas não com esse dono; sem elevação a
# criação com esse dono falha e nada é criado). '' = sem pasta segura.
# Sem Test-Admin aqui: o IsInRole custa dezenas de ms em processo novo (filho -Teste).
# +--------------------------------------------------------------------------+
# | PASTA PROTEGIDA DE TRABALHO
# | O que faz: Cria (ou reaproveita) uma pasta em ProgramData que só
# |            administradores alteram, e confere se ela é mesmo confiável.
# | Por quê:   É ali que ficam a cópia do script, o código compilado e os
# |            backups. Se ficassem numa pasta comum, um programa malicioso
# |            poderia trocá-los.
# +--------------------------------------------------------------------------+
function Get-PastaSegura {
    if ($script:PastaSeguraLida) { return $script:PastaSegura }
    $script:PastaSeguraLida = $true
    $script:PastaSegura = ''
    try {
        $p = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'InstalaTLS'
        if (-not [IO.Directory]::Exists($p)) { [void][IO.Directory]::CreateDirectory($p, (New-AclSegura)) }
        if ([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) { return '' }
        $dono = [IO.Directory]::GetAccessControl($p, [Security.AccessControl.AccessControlSections]::Owner).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($dono -eq 'S-1-5-32-544' -or $dono -eq 'S-1-5-18') { $script:PastaSegura = $p }
    } catch { }
    return $script:PastaSegura
}

# Compilar o C# custa de 0,7 s (PC rápido) a alguns segundos (PDV fraco) e
# acontecia na abertura e em cada teste. Compila uma vez para uma DLL (nome =
# hash do código: mudou o código, gera outra) e reaproveita.
# Elevado: a DLL fica na pasta protegida (em %TEMP% outro processo do usuário
# poderia trocá-la e ganhar o administrador no LoadFile); sem pasta protegida,
# compila em memória. Sem elevação não há o que proteger: segue em %TEMP%.
# +--------------------------------------------------------------------------+
# | CARREGAR AS PEÇAS EM C#
# | O que faz: Carrega o pequeno código em C# que conversa com a CliSiTef,
# |            com o MySQL e com o teclado. Na primeira vez compila e guarda;
# |            nas outras só carrega.
# | Por quê:   Compilar toda vez deixava o script lento (segundos num PDV
# |            fraco). Guardar pronto, em pasta protegida, deixa rápido e
# |            seguro.
# +--------------------------------------------------------------------------+
function Import-Nativo {
    if ('TlsNat' -as [type]) { return }
    $md5 = [Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($script:FonteNativa))
    $nome = 'InstalaTLS_' + ([BitConverter]::ToString($md5) -replace '-', '').Substring(0, 12) + '.dll'
    $seg = Get-PastaSegura
    if ($seg) {
        $dll = Join-Path $seg $nome
        try {
            if (-not (Test-Path -LiteralPath $dll)) {
                Write-Host '  > Preparando componentes (só na primeira vez neste PDV, alguns segundos)...' -ForegroundColor Gray
                Add-Type -TypeDefinition $script:FonteNativa -Language CSharp -OutputAssembly $dll -OutputType Library
            }
            [void][Reflection.Assembly]::LoadFile($dll)
        } catch { }
    }
    # Pasta protegida inacessível (sem elevação): cache antigo em %TEMP%, só para não-admin.
    if (-not ('TlsNat' -as [type]) -and -not (Test-Admin)) {
        $dll = Join-Path $env:TEMP $nome
        try {
            if (-not (Test-Path -LiteralPath $dll)) {
                Add-Type -TypeDefinition $script:FonteNativa -Language CSharp -OutputAssembly $dll -OutputType Library
            }
            [void][Reflection.Assembly]::LoadFile($dll)
        } catch { }
    }
    if (-not ('TlsNat' -as [type])) { Add-Type -TypeDefinition $script:FonteNativa -Language CSharp }
}

# =========================================================
# HELPERS GERAIS / LOG
# =========================================================

# +--------------------------------------------------------------------------+
# | ANOTAR NO LOG
# | O que faz: Escreve uma linha com data e hora no arquivo de log da
# |            execução.
# | Por quê:   Se algo der errado, o log mostra exatamente o que aconteceu,
# |            passo a passo.
# +--------------------------------------------------------------------------+
function Write-Log([string]$m) {
    if (-not $script:Audit) { return }
    $linha = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    try { [IO.File]::AppendAllText($script:Audit, $linha + "`r`n", [Text.Encoding]::UTF8) } catch { }
}

# +--------------------------------------------------------------------------+
# | SEPARADOR NO LOG
# | O que faz: Escreve uma linha de traços no log.
# | Por quê:   Separa visualmente uma etapa da outra, facilitando a leitura.
# +--------------------------------------------------------------------------+
function Write-LogSep { Write-Log '----------------------------------------------------------------' }

# +--------------------------------------------------------------------------+
# | ESCONDER SEGREDO
# | O que faz: Troca o meio de um valor por asteriscos (ex.: 27****31).
# | Por quê:   Token e senha não podem aparecer inteiros no log nem na tela.
# +--------------------------------------------------------------------------+
function Get-Mascara([string]$v) {
    if (-not $v -or $v.Length -le 4) { return '****' }
    return $v.Substring(0, 2) + '****' + $v.Substring($v.Length - 2)
}

# +--------------------------------------------------------------------------+
# | SÓ NÚMEROS
# | O que faz: Tira tudo que não é número de um texto.
# | Por quê:   CNPJ, caixa e código Fiserv vêm com pontos, traços ou espaços;
# |            a CliSiTef e o banco querem só números.
# +--------------------------------------------------------------------------+
function Get-Digitos([string]$s) {
    if (-not $s) { return '' }
    return ($s -replace '[^0-9]', '')
}

# +--------------------------------------------------------------------------+
# | LER UMA LINHA DE ARQUIVO
# | O que faz: Pega uma linha específica de um arquivo .ini, sem espaços
# |            sobrando.
# | Por quê:   Os arquivos de configuração do checkout guardam cada
# |            informação numa linha fixa.
# +--------------------------------------------------------------------------+
function Get-Linha($linhas, [int]$i) {
    if ($linhas -and $i -lt @($linhas).Count -and $null -ne @($linhas)[$i]) { return ([string]@($linhas)[$i]).Trim() }
    return ''
}

# +--------------------------------------------------------------------------+
# | MENSAGEM DE ERRO LIMPA
# | O que faz: Pega a mensagem de erro mais útil, sem a parte técnica
# |            repetida.
# | Por quê:   Mostrar ao operador uma frase que ele entenda, e não um bloco
# |            de texto técnico.
# +--------------------------------------------------------------------------+
function Get-MsgErro($erro) {
    $e = $erro.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

# +--------------------------------------------------------------------------+
# | ESTÁ COMO ADMINISTRADOR?
# | O que faz: Confere se o script está rodando com permissão de
# |            administrador.
# | Por quê:   Gravar configuração do TEF e instalar serviços exige
# |            administrador.
# +--------------------------------------------------------------------------+
function Test-Admin {
    # Cast em vez de New-Object (mesmo construtor, sem o custo do 1o New-Object do processo).
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# +--------------------------------------------------------------------------+
# | MENSAGEM PASSAGEIRA DA CLISITEF
# | O que faz: Diz se uma mensagem da CliSiTef é só de passagem (ex.:
# |            "Conectando Servidor").
# | Por quê:   No fim do teste mostramos a mensagem que realmente importa,
# |            não as intermediárias.
# +--------------------------------------------------------------------------+
function Test-MsgTransitoria([string]$msg) {
    if (-not $msg) { return $true }
    if ($msg -eq 'Conectando Servidor') { return $true }
    if ($msg -eq 'Servidor Conectado') { return $true }
    if ($msg -like 'v.*Selecione a opcao desejada') { return $true }
    if ($msg -like '1:Teste de comunicacao*') { return $true }
    return $false
}

# +--------------------------------------------------------------------------+
# | LIMPAR MENSAGEM DA CLISITEF
# | O que faz: Remove quebras de linha e espaços sobrando da mensagem da
# |            CliSiTef.
# | Por quê:   Mensagem limpa fica legível na tela e no log.
# +--------------------------------------------------------------------------+
function Format-MsgSiTef([string]$m) {
    if (-not $m) { return '' }
    return ($m -replace "`r", '').Trim()
}

# =========================================================
# LOCALIZACAO DE ARQUIVOS / LEITURA DE CONFIGURACAO
# =========================================================

# Procura <unidade>:\Checksup\Checksup.ini em todas as unidades. Unidade de
# rede vira caminho UNC: o processo elevado (admin) nao enxerga as letras
# mapeadas pelo usuario.
# +--------------------------------------------------------------------------+
# | ACHAR O CHECKSUP.INI
# | O que faz: Procura o arquivo Checksup.ini em todas as unidades, inclusive
# |            de rede, e devolve o caminho completo de rede.
# | Por quê:   É nele que está o endereço do banco de dados da loja. O
# |            caminho de rede completo é necessário porque, como
# |            administrador, o Windows não enxerga as letras de unidade do
# |            usuário.
# +--------------------------------------------------------------------------+
function Find-ChecksupIni {
    $candidatos = @()
    try {
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if ([string]$d.DriveType -eq 'CDRom') { continue }
            $letra = $d.Name.Substring(0, 2)
            $base = $d.Name
            if ([string]$d.DriveType -eq 'Network') {
                # Registro primeiro (instantâneo); WMI só se a unidade não estiver lá.
                $rp = ''
                try { $rp = (Get-ItemProperty -LiteralPath ('HKCU:\Network\' + $letra.Substring(0, 1)) -ErrorAction Stop).RemotePath } catch { }
                if (-not $rp) {
                    try {
                        $disco = Get-WmiObject Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $letra)
                        if ($disco) { $rp = $disco.ProviderName }
                    } catch { }
                }
                if ($rp) { $base = $rp.TrimEnd('\') + '\' }
            }
            $candidatos += (Join-Path $base 'Checksup\Checksup.ini')
        }
    } catch { }
    try {
        foreach ($k in @(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
            $rp = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).RemotePath
            if ($rp) { $candidatos += (Join-Path $rp 'Checksup\Checksup.ini') }
        }
    } catch { }
    foreach ($c in $candidatos) {
        try { if (Test-CaminhoRapido $c) { return $c } } catch { }
    }
    return ''
}

# Caminho de rede (\\servidor\...) fora do ar trava o Test-Path por até um minuto:
# testa num runspace à parte e desiste em 3 s. Caminho local testa direto.
function Test-CaminhoRapido([string]$c, [int]$ms = 3000) {
    if ($c -notmatch '^\\\\') { return (Test-Path -LiteralPath $c) }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript('param($c) [IO.File]::Exists($c)').AddArgument($c)
    $h = $ps.BeginInvoke()
    if (-not $h.AsyncWaitHandle.WaitOne($ms)) { return $false }
    try { return [bool](@($ps.EndInvoke($h)) | Select-Object -First 1) } catch { return $false } finally { $ps.Dispose() }
}

# A senha nunca vai ao log, nem em parte: o mascaramento 2+2 revelava 4 de 5 letras.
# +--------------------------------------------------------------------------+
# | DECIFRAR A SENHA DO BANCO
# | O que faz: Decifra a senha do MySQL que o próprio sistema Hipcom guarda
# |            cifrada no IntegracaoDB.ini (linha 4) e no Checksup.ini.
# | Por quê:   Assim nenhuma senha fica escrita neste script: ela sai do
# |            próprio PDV, como faz o "Dcrypdbf" do descomp da Hipcom.
# +--------------------------------------------------------------------------+
# Cifra do Crypdbf: troca de letras com 3 tabelas que se revezam por posição
# (1a, 2a, 3a letra, depois repete). Cada tabela abaixo é a inversa medida no
# descomp: a letra cifrada de código N (32 a 126) vira o caractere na posição
# N-32. Fora dessa faixa, o caractere fica igual.
$script:TabDcrypDbf = @(
    ' /",mnv''xzcl#:@!Z?><MNBVCX-_3L21.u68tgrew]q\=45[pjfyda7h9s0OKIb;`U^*TGREW}Q|+$%{PJFYDA&H(S)oki~',
    ' \"-097''5462E#WQ$|+_)(*&^%zZe@wq=/yi,kmnbdvcxrtsa;j.hfulogp}!{83`?YI<KMNBDVCXRTSA:J>HFULOGP]1[~',
    ' A"DFGJ''L:KW-q=\;asdfghjkl#3_w+|SV*^NYM<>{?!@)(}ZRUBIP&T%O$xecHQ`v86nym,.[/1209]zrubip7t5o4XEC~'
)

function Unprotect-SenhaHipcom([string]$cifrada) {
    if (-not $cifrada) { return '' }
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $cifrada.Length; $i++) {
        $c = [int]$cifrada[$i]
        if ($c -ge 32 -and $c -le 126) { [void]$sb.Append($script:TabDcrypDbf[$i % 3][$c - 32]) }
        else { [void]$sb.Append($cifrada[$i]) }
    }
    return $sb.ToString()
}

# +--------------------------------------------------------------------------+
# | USUÁRIO E SENHA DO INTEGRACAODB.INI
# | O que faz: Lê o usuário (linha 3) e a senha cifrada (linha 4) do
# |            IntegracaoDB.ini e decifra a senha.
# | Por quê:   É a credencial que o próprio checkout usa para entrar no banco.
# +--------------------------------------------------------------------------+
function Read-CredIntegracao {
    $l = @(Get-Content -LiteralPath $INTEGRACAO_INI)
    return @{ Usuario = (Get-Linha $l 2); Senha = (Unprotect-SenhaHipcom (Get-Linha $l 3)) }
}

# +--------------------------------------------------------------------------+
# | SEPARAR ENDEREÇO E PORTA
# | O que faz: Separa "192.168.0.10:3306" em endereço e porta.
# | Por quê:   A conexão com o banco precisa dos dois separados.
# +--------------------------------------------------------------------------+
function Split-HostPorta([string]$h) {
    $porta = 3306
    if ($h -match '^(.+):([0-9]+)$') { $h = $matches[1]; $porta = [int]$matches[2] }
    return @($h, $porta)
}

# +--------------------------------------------------------------------------+
# | DADOS DO BANCO DA LOJA
# | O que faz: Lê o endereço, usuário, banco e loja no Checksup.ini (ou, se
# |            não houver, no IntegracaoDB.ini).
# | Por quê:   Sem isso não dá para gravar nem consultar o token TLS do
# |            caixa.
# +--------------------------------------------------------------------------+
function Read-ConfigBanco {
    $cfg = @{ Origem = ''; Host = ''; Porta = 3306; Usuario = ''; Senha = ''; Banco = ''; Loja = '' }

    $ck = $script:ChecksupIniUsado
    if ($ck -and (Test-Path -LiteralPath $ck)) {
        $l = @(Get-Content -LiteralPath $ck)
        $partes = @((Get-Linha $l 0) -split '\s+' | Where-Object { $_ })
        if ($partes.Count -ge 1) {
            $hp = Split-HostPorta $partes[0]
            $cfg.Host = $hp[0]; $cfg.Porta = $hp[1]
            # Linha 1: "ip [usuario senhaCifrada]". Com senha cifrada, decifra; sem ela,
            # usa a credencial do IntegracaoDB.ini (a mesma que o checkout usa).
            if ($partes.Count -ge 3) {
                $cfg.Usuario = $partes[1]
                $cfg.Senha = Unprotect-SenhaHipcom $partes[2]
            } elseif ($partes.Count -eq 1 -and $script:CredAberta -and $script:CredAberta.Root) {
                # Sem usuário = root. A senha do root só existe no atalho cifrado (modo automático).
                $cfg.Usuario = 'root'
                $cfg.Senha = $script:CredAberta.Root
            } else {
                $ci = Read-CredIntegracao
                $cfg.Usuario = $ci.Usuario
                $cfg.Senha = $ci.Senha
            }
            $cfg.Banco = Get-Linha $l 1
            $cfg.Loja = Get-Linha $l 2
            $cfg.Origem = $ck
            return $cfg
        }
    }

    # Fallback: IntegracaoDB.ini (host, banco, usuario, senha criptografada, ...)
    $l = @(Get-Content -LiteralPath $INTEGRACAO_INI)
    $hp = Split-HostPorta (Get-Linha $l 0)
    $cfg.Host = $hp[0]; $cfg.Porta = $hp[1]
    $cfg.Banco = Get-Linha $l 1
    $ci = Read-CredIntegracao
    $cfg.Usuario = $ci.Usuario
    $cfg.Senha = $ci.Senha
    $cfg.Origem = $INTEGRACAO_INI
    return $cfg
}

# Le o primeiro registro valido de um .dbf (dBase III/IV; dBase 7 basico).
# +--------------------------------------------------------------------------+
# | LER O PDVCTR.DBF
# | O que faz: Lê o primeiro registro do arquivo pdvctr.dbf (CNPJ, código
# |            Fiserv, IP do TEF).
# | Por quê:   São os dados de identificação da loja que a Fiserv usa no
# |            teste. O arquivo é lido direto, sem precisar de programa
# |            extra.
# +--------------------------------------------------------------------------+
function Read-Dbf([string]$caminho) {
    $fs = New-Object IO.FileStream($caminho, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $b = New-Object byte[] ([int]$fs.Length)
        [void]$fs.Read($b, 0, $b.Length)
    } finally { $fs.Close() }

    $n  = [BitConverter]::ToInt32($b, 4)
    $hl = [BitConverter]::ToUInt16($b, 8)
    $rl = [BitConverter]::ToUInt16($b, 10)
    # Cabeçalho corrompido (registro de tamanho 0) prenderia o laço em até 2^31 voltas.
    if ($rl -lt 1) { return $null }
    $tam = 32; $ini = 32; $tamNome = 11; $offTipo = 11; $offLen = 16
    if (($b[0] -band 0x07) -eq 4) { $tam = 48; $ini = 68; $tamNome = 32; $offTipo = 32; $offLen = 33 }

    $campos = @()
    for ($o = $ini; ($o + $tam) -le $hl -and $b[$o] -ne 0x0D; $o += $tam) {
        $nome = [Text.Encoding]::ASCII.GetString($b, $o, $tamNome).Trim([char]0).Trim()
        $campos += ,@($nome, [int]$b[$o + $offLen])
    }

    $enc = [Text.Encoding]::GetEncoding(1252)
    for ($r = 0; $r -lt $n; $r++) {
        $pos = $hl + $r * $rl
        if (($pos + $rl) -gt $b.Length) { break }
        if ($b[$pos] -eq 0x2A) { continue }
        $reg = @{}
        $p = $pos + 1
        foreach ($c in $campos) {
            $reg[$c[0].ToUpper()] = $enc.GetString($b, $p, $c[1]).Trim()
            $p += $c[1]
        }
        return $reg
    }
    return $null
}

# +--------------------------------------------------------------------------+
# | ACHAR A BIBLIOTECA DO MYSQL
# | O que faz: Procura na pasta do checkout a DLL que conversa com o MySQL.
# | Por quê:   Usamos a mesma biblioteca que o checkout já usa: nada a
# |            instalar no PDV.
# +--------------------------------------------------------------------------+
function Find-MysqlDll {
    foreach ($nome in @('libmysql.dll', 'LIBMYSQL51.DLL', 'LIBMYSQL41.DLL')) {
        $p = Join-Path $CheckoutDir $nome
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return ''
}

# =========================================================
# MODO TESTE (processo filho 32-bit; chama a CliSiTef direto)
# =========================================================

# +--------------------------------------------------------------------------+
# | AVISAR O PROCESSO PRINCIPAL
# | O que faz: O processo de teste escreve aqui o andamento (porcentagem, log
# |            e resultado).
# | Por quê:   O teste roda separado; é por esse arquivo que a tela principal
# |            acompanha o progresso.
# +--------------------------------------------------------------------------+
function Write-Status([string]$linha) {
    if (-not $Status) { return }
    for ($i = 0; $i -lt 40; $i++) {
        try { [IO.File]::AppendAllText($Status, $linha + "`r`n", (New-Object Text.UTF8Encoding($false))); return } catch { Start-Sleep -Milliseconds 50 }
    }
}

# +--------------------------------------------------------------------------+
# | ENVIAR O RESULTADO DO TESTE
# | O que faz: Grava o resultado final do teste (código e mensagem) para a
# |            tela principal ler.
# | Por quê:   A tela principal precisa saber se deu certo e qual foi a
# |            mensagem da Fiserv.
# +--------------------------------------------------------------------------+
function Send-Resultado([int]$codigo, [string]$msg) {
    $limpa = { param($t) if ($t) { ($t -replace '[|\r\n]', ' ') } else { '' } }
    Write-Status ('RESULT|{0}|{1}|{2}|{3}' -f $codigo, (& $limpa $msg), (& $limpa $script:TUtil), (& $limpa $script:TUltima))
    return $codigo
}

# +--------------------------------------------------------------------------+
# | MELHOR MENSAGEM DO TESTE
# | O que faz: Escolhe a mensagem mais útil recebida da CliSiTef durante o
# |            teste.
# | Por quê:   Quando dá erro, mostrar o motivo real (ex.: "Sem conexão
# |            Servidor") ajuda a resolver.
# +--------------------------------------------------------------------------+
function Get-MsgResolvida([string]$fallback) {
    if ($script:TUtil) { return $script:TUtil }
    if ($script:TUltima) { return $script:TUltima }
    return $fallback
}

# Codigos (iguais ao run_test_once do Linux):
#   0 sucesso | 11 configura falhou | 12 inicia falhou | 21 resultado negativo
#  40 timeout | 90 excecao | 99 cancelado pelo usuario
# +--------------------------------------------------------------------------+
# | O TESTE DE COMUNICAÇÃO EM SI
# | O que faz: Carrega a CliSiTef, configura a loja e o caixa e faz o "Teste
# |            de comunicação" (função 110), respondendo sozinho às perguntas
# |            da CliSiTef.
# | Por quê:   É a prova real de que o PDV fala com a Fiserv (TLS) ou com a
# |            GSurf, igual ao teste feito à mão no checkout.
# +--------------------------------------------------------------------------+
function Invoke-ModoTeste {
    $script:TUltima = ''
    $script:TUtil = ''
    $s = $null
    $iniciou = $false
    $data = Get-Date -Format 'yyyyMMdd'
    $hora = Get-Date -Format 'HHmmss'
    $cupom = $hora
    try {
        Import-Nativo
        [Environment]::CurrentDirectory = $CheckoutDir
        Set-Location -LiteralPath $CheckoutDir
        Write-Status ('PCT|{0}' -f $PctIni)
        Write-Status ('LOG|MODO={0} DLL={1}' -f $Modo, $SITEF_DLL)
        $s = New-Object TlsSiTef -ArgumentList $SITEF_DLL

        Write-Status ('LOG|CONFIGURA ip={0} idLoja={1} idTerminal={2} parms={3}' -f $IpSiTef, $IdLoja, $IdTerm, $Parms)
        $r = $s.Configurar($IpSiTef, $IdLoja, $IdTerm, $Parms)
        Write-Status ('LOG|CONFIGURA_RESULT={0}' -f $r)
        if ($r -ne 0) { return (Send-Resultado 11 ('A CliSiTef recusou a configuração (retorno {0})' -f $r)) }
        $base = $PctIni + 5
        Write-Status ('PCT|{0}' -f $base)

        $iniciou = $true
        $r = $s.Iniciar(110, '0', $cupom, $data, $hora, $OPERADOR, '{DevolveStringQRCode=1}')
        Write-Status ('LOG|INICIA_RESULT={0}' -f $r)
        if ($r -eq 0) {
            $s.Finalizar(1, $cupom, $data, $hora)
            return (Send-Resultado 0 'Servidor Ativo')
        }
        if ($r -ne 10000) { return (Send-Resultado 12 ('A CliSiTef não iniciou o teste (retorno {0})' -f $r)) }

        $inicio = Get-Date
        $resp = $null
        $selecionou = $false
        $ultPct = -1
        $passo = 0
        while ($true) {
            $passo++
            $dec = ((Get-Date) - $inicio).TotalSeconds
            if ($dec -ge $TimeoutSeg) {
                Write-Status ('LOG|TIMEOUT apos {0} s' -f $TimeoutSeg)
                $s.Finalizar(0, $cupom, $data, $hora)
                return (Send-Resultado 40 (Get-MsgResolvida 'Sem resposta do servidor (tempo esgotado)'))
            }
            if ($Cancelar -and (Test-Path -LiteralPath $Cancelar)) {
                Write-Status 'LOG|ABORTO: cancelamento pedido pelo operador (Ctrl+C)'
                $s.Finalizar(0, $cupom, $data, $hora)
                return (Send-Resultado 99 'Teste cancelado')
            }

            # Progressao ease-out quadratica (igual ao Linux), por tempo.
            $t = $dec / $TimeoutSeg
            $pct = [int]($base + ($PctMax - $base) * (2 * $t - $t * $t))
            if ($pct -ne $ultPct) { Write-Status ('PCT|{0}' -f $pct); $ultPct = $pct }

            $r = $s.Continuar($resp, 0)
            $resp = $null
            $msg = Format-MsgSiTef $s.Texto()
            Write-Status ('LOG|CONTINUA_{0} ret={1} cmd={2} tipo={3} tmin={4} tmax={5} msg={6}' -f $passo, $r, $s.Comando, $s.TipoCampo, $s.TamMinimo, $s.TamMaximo, ($msg -replace '[\r\n]', ' '))

            if ($r -ne 10000) {
                if ($r -eq 0) {
                    $s.Finalizar(1, $cupom, $data, $hora)
                    return (Send-Resultado 0 'Servidor Ativo')
                }
                $s.Finalizar(0, $cupom, $data, $hora)
                return (Send-Resultado 21 (Get-MsgResolvida ('Falha na comunicação (retorno {0})' -f $r)))
            }

            if ($msg) {
                $script:TUltima = $msg
                if (-not (Test-MsgTransitoria $msg)) { $script:TUtil = $msg }
                elseif ($msg -match '127\.0\.0\.1|fiservapp\.com') { $script:TUtil = $msg }

                if (-not $selecionou -and $msg -match '1:Teste de comunicacao') {
                    Write-Status 'LOG|DECISAO: menu Teste de comunicacao (opcao 1)'
                    $resp = '1'; $selecionou = $true
                    continue
                }
                if ($msg -match '^Confirma o teste de comunicacao .*fiservapp\.com') {
                    Write-Status 'LOG|MARCO: confirmacao do teste TLS (opcao 0)'
                    $resp = '0'
                    continue
                }
                if ($msg -match '^Confirma o teste de comunicacao .*127\.0\.0\.1') {
                    Write-Status 'LOG|MARCO: confirmacao do teste GSURF (opcao 0)'
                    $resp = '0'
                    continue
                }
            }
            if ($s.Comando -eq 23) { Start-Sleep -Milliseconds 100 }
        }
    } catch {
        $e = Get-MsgErro $_
        Write-Status ('LOG|EXCECAO: {0}' -f $e)
        if ($s -and $iniciou) { try { $s.Finalizar(0, $cupom, $data, $hora) } catch { } }
        return (Send-Resultado 90 ('Erro na CliSiTef: {0}' -f $e))
    }
}

# +--------------------------------------------------------------------------+
# | MODO DE TESTE
# | O que faz: Quando o script é aberto como processo de teste, faz só o
# |            teste e fecha.
# | Por quê:   A CliSiTef só lê a configuração ao ser carregada; um processo
# |            novo a cada teste garante que ela use a configuração recém-
# |            gravada.
# +--------------------------------------------------------------------------+
if ($Teste) {
    $codigo = Invoke-ModoTeste
    exit $codigo
}

# =========================================================
# MODO REQUISITOS (processo filho num console oculto)
# =========================================================
# O RequisitosGSurf.exe exige console de verdade na entrada e na saída (com
# pipe/arquivo abre "Console Error GetConsoleMode/GetConsoleScreenBufferInfo").
# Este processo tem console próprio oculto: roda o exe nele e digita Enter
# (região padrão 3 e o "pressione qualquer tecla" do fim). O resultado sai do
# RequisitosGSurf.log que o exe grava na pasta dele.
# +--------------------------------------------------------------------------+
# | MODO VERIFICADOR DA GSURF
# | O que faz: Roda o RequisitosGSurf.exe numa janela própria escondida e
# |            aperta Enter por ele.
# | Por quê:   Esse programa da GSurf exige uma janela de verdade; sem isso
# |            ele mostra "Console Error". Escondida, o operador não vê nada.
# +--------------------------------------------------------------------------+
if ($Requisitos) {
    Import-Nativo
    $p = Start-Process -FilePath $Requisitos -WorkingDirectory (Split-Path -Parent $Requisitos) -NoNewWindow -PassThru
    $t0 = Get-Date
    while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt 170) {
        try { [TlsTecla]::Enter() } catch { }
        Start-Sleep -Milliseconds 1500
    }
    if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    exit 0
}

# +--------------------------------------------------------------------------+
# | MODO CERTIFICADO AUTOMÁTICO (processo filho num console oculto)
# | O que faz: Lê login, senha e OTP do arquivo da pasta protegida (e apaga
# |            na hora), roda o InstaladorGSurf.exe e digita as três respostas
# |            neste console oculto. No fim, grava o texto da tela (com a senha
# |            trocada por ****) para o processo principal saber o resultado.
# | Por quê:   Instalar o certificado sem ninguém digitar e sem expor a senha.
# +--------------------------------------------------------------------------+
if ($Certificado) {
    Import-Nativo
    $resp = @([IO.File]::ReadAllLines($CredArq))
    [IO.File]::Delete($CredArq)
    $senhaTela = ''
    if ($resp.Count -ge 2) { $senhaTela = $resp[1] }
    $p = Start-Process -FilePath $Certificado -WorkingDirectory (Split-Path -Parent $Certificado) -NoNewWindow -PassThru
    Start-Sleep -Milliseconds 1500
    foreach ($v in $resp) { try { [TlsTecla]::Digitar($v); [TlsTecla]::Enter() } catch { }; Start-Sleep -Milliseconds 700 }
    $resp = $null
    $t0 = Get-Date
    while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt 180) {
        Start-Sleep -Milliseconds 500
        # Passado o tempo de instalar, Enter responde o "pressione uma tecla" do fim.
        if (((Get-Date) - $t0).TotalSeconds -gt 8) { try { [TlsTecla]::Enter() } catch { } }
    }
    $rc = 98
    if ($p.HasExited) { $rc = $p.ExitCode } else { try { $p.Kill() } catch { } }
    $tela = ''
    try { $tela = [TlsTecla]::Tela(60, 120) } catch { }
    if ($senhaTela) { $tela = $tela.Replace($senhaTela, '****') }
    $senhaTela = $null
    try { [IO.File]::WriteAllText($Status, $tela) } catch { }
    exit $rc
}

# =========================================================
# AMBIENTE: 32-bit + administrador + STA (relanca se preciso)
# =========================================================

# +--------------------------------------------------------------------------+
# | REABRIR COMO ADMINISTRADOR
# | O que faz: Se o script não estiver como administrador e em 32 bits, ele
# |            se reabre assim (aparece o aviso do Windows).
# | Por quê:   A CliSiTef é 32 bits e as alterações exigem administrador. O
# |            operador não precisa fazer nada de especial para abrir.
# +--------------------------------------------------------------------------+
function Confirm-Ambiente {
    $is32 = ([IntPtr]::Size -eq 4)
    $adm = Test-Admin
    if ($is32 -and $adm) { return }

    if (-not $script:SelfPath) {
        Write-Host 'Abra o InstalaTLS pelo arquivo TLS.ps1.'
        exit 1
    }
    # Pasta do Windows pela API, não por %windir% (variável que o usuário pode trocar no HKCU).
    $win = Split-Path -Parent ([Environment]::SystemDirectory)
    $ps = Join-Path $win 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { $ps = Join-Path $win 'System32\WindowsPowerShell\v1.0\powershell.exe' }

    # Acha o Checksup.ini antes de elevar: o admin nao ve as unidades mapeadas.
    $ck = $ChecksupIni
    if (-not $ck) { Write-Host '  > Procurando o Checksup.ini...' -ForegroundColor Gray; $ck = Find-ChecksupIni }
    # Aspas no caminho (RemotePath do registro) injetariam parâmetros no processo elevado.
    if ($ck -match '"') { $ck = '' }
    if ($CheckoutDir -match '"') { Write-Host 'Pasta do Checkout inválida.'; exit 1 }

    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -CheckoutDir "{1}"' -f $script:SelfPath, $CheckoutDir
    if ($ck) { $a += (' -ChecksupIni "{0}"' -f $ck.TrimEnd('\')) }
    # Modo automático: o bloco cifrado só tem letras de base64 (validado: nada de aspas).
    if ($Auto) {
        if ($Cred -notmatch '^[A-Za-z0-9+/=]{40,}$') { Write-Host 'Credencial do atalho inválida.'; exit 1 }
        $a += (' -Auto -Cred {0}' -f $Cred)
    }
    if ($adm) { Write-Host '  > Abrindo a janela do InstalaTLS...' -ForegroundColor Gray }
    else { Write-Host '  > Abrindo como administrador: confirme o aviso do Windows (Sim).' -ForegroundColor Yellow }
    try {
        if ($adm) { Start-Process -FilePath $ps -ArgumentList $a }
        else { Start-Process -FilePath $ps -ArgumentList $a -Verb RunAs }
    } catch {
        Write-Host 'É preciso permitir a execução como administrador.'
        exit 1
    }
    exit 0
}

# =========================================================
# INTERFACE (console do PowerShell; sem janelas)
# =========================================================
# Caixa costuma rodar em 640x480: tudo quebra pela largura real da janela.
# Console do Windows nao tem negrito: destaque = cor clara + faixa com fundo.
#   titulo: faixa DarkCyan | rotulo: Gray | valor: Yellow | pergunta: Cyan
#   OK: Green | erro: Red | aviso: Yellow | dica: DarkGray

# +--------------------------------------------------------------------------+
# | LARGURA DA TELA
# | O que faz: Descobre quantas letras cabem por linha na janela.
# | Por quê:   Muitos caixas usam tela pequena (640x480); o texto quebra no
# |            tamanho certo.
# +--------------------------------------------------------------------------+
function Get-LarguraTexto {
    $w = 56
    try { $w = [Console]::WindowWidth - 4 } catch { }
    if ($w -lt 30) { $w = 30 }
    if ($w -gt 76) { $w = 76 }
    return $w
}

# Quebra $texto em linhas de no maximo $larg caracteres.
# +--------------------------------------------------------------------------+
# | QUEBRAR TEXTO
# | O que faz: Divide um texto longo em linhas que cabem na tela.
# | Por quê:   Evita texto cortado ou embaralhado na janela.
# +--------------------------------------------------------------------------+
function Split-Linhas([string]$texto, [int]$larg) {
    $saida = @()
    foreach ($par in ($texto -split "`r?`n")) {
        $linha = ''
        foreach ($pal in ($par -split ' ')) {
            while ($pal.Length -gt $larg) {
                if ($linha) { $saida += $linha; $linha = '' }
                $saida += $pal.Substring(0, $larg)
                $pal = $pal.Substring($larg)
            }
            if (-not $linha) { $linha = $pal }
            elseif (($linha.Length + 1 + $pal.Length) -le $larg) { $linha = $linha + ' ' + $pal }
            else { $saida += $linha; $linha = $pal }
        }
        $saida += $linha
    }
    return ,$saida
}

# +--------------------------------------------------------------------------+
# | ESCREVER TEXTO COLORIDO
# | O que faz: Escreve um texto na tela, já quebrado, na cor escolhida.
# | Por quê:   Cores ajudam: verde é OK, vermelho é erro, amarelo é
# |            recomendação.
# +--------------------------------------------------------------------------+
function Write-Linhas([string]$texto, [string]$cor) {
    if ($script:Quieto) { return }
    if (-not $cor) { $cor = 'White' }
    foreach ($l in (Split-Linhas $texto (Get-LarguraTexto))) { Write-Host ('  ' + $l) -ForegroundColor $cor }
}

# +--------------------------------------------------------------------------+
# | FAIXA COLORIDA
# | O que faz: Escreve uma faixa com fundo colorido (ex.: ERRO em vermelho).
# | Por quê:   Destaca títulos e resultados para o operador achar rápido.
# +--------------------------------------------------------------------------+
function Write-Faixa([string]$texto, [string]$fundo, [string]$frente) {
    $larg = (Get-LarguraTexto) + 2
    foreach ($l in (Split-Linhas $texto ($larg - 2))) {
        Write-Host ' ' -NoNewline
        Write-Host ((' ' + $l).PadRight($larg)) -BackgroundColor $fundo -ForegroundColor $frente
    }
}

# +--------------------------------------------------------------------------+
# | TÍTULO DE TELA
# | O que faz: Mostra o título de uma etapa em faixa azul.
# | Por quê:   O operador sabe em que parte do processo está.
# +--------------------------------------------------------------------------+
function Write-Titulo([string]$texto) {
    if ($script:Quieto) { return }
    Write-Host ''
    $l = @($texto -split "`r?`n")
    # Título só com letra clara (sem fundo): fundo colorido fica só para a opção selecionada.
    Write-Host ('  ' + $l[0]) -ForegroundColor White
    if ($l.Count -gt 1) { Write-Linhas (($l[1..($l.Count - 1)]) -join "`n") 'White' }
}

# "  Rotulo ......: valor" com valor em destaque.
# +--------------------------------------------------------------------------+
# | CAMPO E VALOR
# | O que faz: Mostra "Rótulo: valor" alinhado (ex.: "Caixa: 6").
# | Por quê:   Leitura rápida dos dados do PDV.
# +--------------------------------------------------------------------------+
function Write-Campo([string]$rotulo, [string]$valor, [string]$cor) {
    if ($script:Quieto) { return }
    if (-not $cor) { $cor = 'Yellow' }
    $tamRot = 14
    $larg = Get-LarguraTexto
    $resto = $larg - $tamRot - 2
    if ($resto -lt 12) { $resto = 12 }
    $linhas = Split-Linhas ([string]$valor) $resto
    Write-Host ('  ' + $rotulo.PadRight($tamRot) + ': ') -NoNewline -ForegroundColor Gray
    Write-Host $linhas[0] -ForegroundColor $cor
    for ($i = 1; $i -lt $linhas.Count; $i++) {
        Write-Host ('  ' + (' ' * ($tamRot + 2)) + $linhas[$i]) -ForegroundColor $cor
    }
}

# +--------------------------------------------------------------------------+
# | DICA EM CINZA
# | O que faz: Mostra uma dica discreta em cinza.
# | Por quê:   Informação de apoio que não deve chamar atenção.
# +--------------------------------------------------------------------------+
function Write-Dica([string]$texto) { if ($script:Quieto) { return }; Write-Host ('  ' + $texto) -ForegroundColor DarkGray }

# +--------------------------------------------------------------------------+
# | LER O QUE O OPERADOR DIGITA
# | O que faz: Mostra uma pergunta e lê a resposta digitada.
# | Por quê:   Usado para o token e respostas simples.
# +--------------------------------------------------------------------------+
function Read-Campo([string]$rotulo) {
    Write-Host ('  ' + $rotulo + ' ') -NoNewline -ForegroundColor Cyan
    return [string](Read-Host)
}

# +--------------------------------------------------------------------------+
# | MENSAGEM DESTACADA
# | O que faz: Mostra uma mensagem com faixa de OK, ERRO ou ATENÇÃO, e anota
# |            no log.
# | Por quê:   Resultado claro para o operador e registrado para o suporte.
# +--------------------------------------------------------------------------+
function Show-Mensagem([string]$texto, [string]$tipo) {
    Write-Log ('UI_MSG[{0}]={1}' -f $tipo, ($texto -replace '[\r\n]+', ' | '))
    if ($script:Quieto) { return }
    Write-Host ''
    if ($tipo -eq 'erro') { Write-Faixa 'ERRO' 'DarkRed' 'White'; Write-Linhas $texto 'Red' }
    elseif ($tipo -eq 'aviso') { Write-Faixa 'ATENÇÃO' 'DarkYellow' 'Black'; Write-Linhas $texto 'Yellow' }
    elseif ($tipo -eq 'ok') { Write-Faixa 'OK' 'DarkGreen' 'White'; Write-Linhas $texto 'Green' }
    else { Write-Linhas $texto 'White' }
}

# +--------------------------------------------------------------------------+
# | PERGUNTA SIM OU NÃO
# | O que faz: Faz uma pergunta e só aceita S ou N.
# | Por quê:   Usado para confirmar fechar o Checkout antes do teste.
# +--------------------------------------------------------------------------+
function Ask-SimNao([string]$texto) {
    Write-Host ''
    Write-Linhas $texto 'White'
    while ($true) {
        $r = (Read-Campo '[S/N]').Trim().ToUpper()
        if ($r -eq 'S' -or $r -eq 'SIM') { Write-Log ('UI_PERGUNTA={0} -> SIM' -f ($texto -replace '[\r\n]+', ' | ')); return $true }
        if ($r -eq 'N' -or $r -eq 'NAO' -or $r -eq 'NÃO') { Write-Log ('UI_PERGUNTA={0} -> NAO' -f ($texto -replace '[\r\n]+', ' | ')); return $false }
        Write-Dica 'Digite S ou N.'
    }
}

# +--------------------------------------------------------------------------+
# | COMEÇAR O PROGRESSO
# | O que faz: Mostra o título da ação e prepara a barra de progresso.
# | Por quê:   O operador vê que o processo está andando.
# +--------------------------------------------------------------------------+
function Start-Progresso([string]$titulo) {
    if (-not $titulo) { $titulo = 'TLS' }
    $script:ProgressoAtivo = $true
    $script:UltMsgTela = ''
    $script:UltPctTela = -1
    $script:BarraNaTela = $false
    Write-Titulo $titulo
    Write-Dica 'Ctrl+C cancela e restaura a configuração anterior.'
}

# +--------------------------------------------------------------------------+
# | ATUALIZAR O PROGRESSO
# | O que faz: Atualiza a porcentagem e a etapa atual.
# | Por quê:   Mostra o andamento sem encher a tela de mensagens.
# +--------------------------------------------------------------------------+
# +--------------------------------------------------------------------------+
# | BARRA DE PROGRESSO
# | O que faz: Desenha "[#####-----]  52%  etapa" sempre na mesma linha,
# |            redesenhando por cima, e apaga a barra quando entra uma etapa
# |            nova (a etapa fica numa linha acima).
# | Por quê:   A faixa padrão do PowerShell aparecia no topo da janela e cobria
# |            o texto. "#" e "-" aparecem certo em qualquer console, até no
# |            Windows 7, e a linha nunca passa da largura da janela.
# +--------------------------------------------------------------------------+
function Get-LarguraLinha {
    $w = 79
    try { $w = [Console]::WindowWidth - 1 } catch { }
    if ($w -lt 40) { $w = 40 }
    return $w
}

function Write-Barra([int]$pct, [string]$msg) {
    $w = Get-LarguraLinha
    $n = 20
    if ($w -ge 70) { $n = 28 }
    $cheio = [int][Math]::Round($n * $pct / 100.0)
    $resto = $w - 11 - $n
    if ($resto -lt 0) { $resto = 0 }
    $rot = [string]$msg
    if ($rot.Length -gt $resto) { $rot = $rot.Substring(0, $resto) }
    Write-Host "`r  [" -NoNewline -ForegroundColor Gray
    if ($cheio -gt 0) { Write-Host ('#' * $cheio) -NoNewline -ForegroundColor Green }
    if ($n - $cheio -gt 0) { Write-Host ('-' * ($n - $cheio)) -NoNewline -ForegroundColor DarkGray }
    Write-Host '] ' -NoNewline -ForegroundColor Gray
    Write-Host ('{0,3}%' -f $pct) -NoNewline -ForegroundColor Yellow
    Write-Host ('  ' + $rot.PadRight($resto)) -NoNewline -ForegroundColor Cyan
    $script:BarraNaTela = $true
}

function Clear-Barra {
    if (-not $script:BarraNaTela) { return }
    Write-Host ("`r" + (' ' * (Get-LarguraLinha)) + "`r") -NoNewline
    $script:BarraNaTela = $false
}

function Set-Progresso([int]$pct, [string]$msg) {
    if (-not $script:ProgressoAtivo) { return }
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    if (-not $msg) { $msg = $script:Rotulo }
    if ($msg -ne $script:UltMsgTela) { Clear-Barra; Write-Linhas ('> ' + $msg) 'Cyan'; $script:UltMsgTela = $msg }
    if ($pct -ne $script:UltPctTela -or -not $script:BarraNaTela) { Write-Barra $pct $msg; $script:UltPctTela = $pct }
    if ($pct -ne $script:UltPctLog -or $msg -ne $script:UltMsgLog) {
        Write-Log ('UI_PROGRESS={0}% MSG={1}' -f $pct, $msg)
        $script:UltPctLog = $pct; $script:UltMsgLog = $msg
    }
}

# +--------------------------------------------------------------------------+
# | FECHAR O PROGRESSO
# | O que faz: Fecha a barra de progresso.
# | Por quê:   Deixa a tela limpa para o resultado.
# +--------------------------------------------------------------------------+
function Close-Progresso {
    if (-not $script:ProgressoAtivo) { return }
    $script:ProgressoAtivo = $false
    # Termina a linha da barra (fica visível no último valor) e libera a tela.
    if ($script:BarraNaTela) { Write-Host ''; $script:BarraNaTela = $false }
}

# +--------------------------------------------------------------------------+
# | CNPJ COM PONTUAÇÃO
# | O que faz: Mostra o CNPJ no formato 00.000.000/0000-00.
# | Por quê:   Fica fácil de conferir com o cadastro da loja.
# +--------------------------------------------------------------------------+
function Format-Cnpj([string]$c) {
    if ($c -match '^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$') {
        return ('{0}.{1}.{2}/{3}-{4}' -f $matches[1], $matches[2], $matches[3], $matches[4], $matches[5])
    }
    return $c
}

# =========================================================
# FINALIZACAO / ROLLBACK
# =========================================================

# Grava em C:\checkout (gravável por usuário comum) sem seguir link plantado no
# destino: apaga só o nome antigo e cria um novo (falha se reaparecer no meio).
# +--------------------------------------------------------------------------+
# | COPIAR COM SEGURANÇA
# | O que faz: Copia um arquivo apagando antes o destino antigo, em vez de
# |            escrever por cima.
# | Por quê:   Impede que um atalho falso plantado no lugar faça o script
# |            sobrescrever outro arquivo do sistema.
# +--------------------------------------------------------------------------+
function Copy-Seguro([string]$de, [string]$para) {
    if ([IO.File]::Exists($para)) {
        [IO.File]::SetAttributes($para, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($para)
    }
    [IO.File]::Copy($de, $para, $false)
}

# Texto para SQL entre aspas: dobra ' e escapa \ (no MySQL a barra também escapa).
# +--------------------------------------------------------------------------+
# | TEXTO SEGURO PARA O BANCO
# | O que faz: Prepara um texto para ir dentro de um comando do banco,
# |            neutralizando aspas e barras.
# | Por quê:   Evita que um valor malicioso vire um comando no banco de dados
# |            (injeção de SQL).
# +--------------------------------------------------------------------------+
function Get-SqlTexto([string]$v) {
    return ($v -replace '\\', '\\' -replace "'", "''")
}

# +--------------------------------------------------------------------------+
# | SALVAR O LOG
# | O que faz: Copia o log desta execução para C:\checkout\InstalaTLS.log.
# | Por quê:   O suporte consegue ver depois tudo o que foi feito.
# +--------------------------------------------------------------------------+
function Complete-Log {
    if ($script:LogSalvo) { return }
    $script:LogSalvo = $true
    try {
        Copy-Seguro $script:Audit $FINAL_LOG_FILE
        Write-Dica ('Log: ' + $FINAL_LOG_FILE)
    } catch {
        Write-Dica ('Não foi possível salvar o log em ' + $FINAL_LOG_FILE + '.')
    }
}

# +--------------------------------------------------------------------------+
# | ENCERRAR COM LIMPEZA
# | O que faz: Fecha a conexão com o banco, apaga temporários, libera a trava
# |            e encerra.
# | Por quê:   Não deixa segredo em memória nem arquivo temporário para trás.
# +--------------------------------------------------------------------------+
function Exit-Script([int]$codigo) {
    Close-Progresso
    Write-Host '  Encerrando...' -ForegroundColor DarkGray
    try { if ($script:Db) { $script:Db.Fechar() } } catch { }
    $script:DbSenha = $null
    $script:TokenTls = $null
    $script:TokenAtual = $null
    $script:OrigToken = $null
    if ($script:TmpDir -and (Test-Path -LiteralPath $script:TmpDir)) {
        try { Remove-Item -LiteralPath $script:TmpDir -Recurse -Force } catch { }
    }
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Close(); $script:Mutex = $null } } catch { }
    $script:Saindo = $true
    Write-Host ''
    try { [void](Read-Host '  Pressione Enter para fechar') } catch { }
    # Tudo já foi limpo: sai direto, sem esperar o PowerShell desmontar a sessão.
    try { [TlsNat]::Encerrar($codigo) } catch { }
    [Environment]::Exit($codigo)
}

# +--------------------------------------------------------------------------+
# | CONVERSAR COM O BANCO
# | O que faz: Executa um comando no MySQL; se a conexão caiu, reconecta e
# |            tenta mais uma vez.
# | Por quê:   Uma queda rápida de rede não derruba a operação.
# +--------------------------------------------------------------------------+
function Invoke-Db([string]$sql, [switch]$Escalar, [switch]$SemRetentar) {
    $tentativas = 2
    if ($SemRetentar) { $tentativas = 1 }
    for ($t = 1; $t -le $tentativas; $t++) {
        try {
            if ($Escalar) { return $script:Db.Escalar($sql) }
            return $script:Db.Executar($sql)
        } catch {
            $e = Get-MsgErro $_
            Write-Log ('MYSQL_ERRO (tentativa {0}/{1}): {2}' -f $t, $tentativas, $e)
            if ($t -ge $tentativas) { throw $e }
            try { $script:Db.Conectar($script:DbHost, [uint32]$script:DbPorta, $script:DbUsuario, $script:DbSenha, $script:DbBanco) }
            catch { throw (Get-MsgErro $_) }
        }
    }
}

# +--------------------------------------------------------------------------+
# | DESFAZER (VOLTAR COMO ESTAVA)
# | O que faz: Restaura o token e o CONFITLS.INI exatamente como estavam
# |            antes da ação.
# | Por quê:   Se algo falhar no meio, o PDV não fica pela metade: volta a
# |            funcionar como antes.
# +--------------------------------------------------------------------------+
function Invoke-Rollback {
    if (-not $script:RollbackOn) {
        Write-Log 'ROLLBACK: já executado ou não habilitado'
        return
    }
    $script:RollbackOn = $false
    Write-LogSep
    Write-Log 'INICIANDO ROLLBACK'
    $falhas = @()

    # Token: DELETE + INSERT do original na mesma conexao/transacao.
    try {
        $where = 'tlsloja={0} AND {1}={2}' -f $TLS_LOJA, $TLS_COL_CAIXA, $script:NumCaixa
        [void](Invoke-Db 'START TRANSACTION' -SemRetentar)
        [void](Invoke-Db ('DELETE FROM {0} WHERE {1}' -f $TLS_TABLE, $where) -SemRetentar)
        if ($script:OrigTokenExiste) {
            [void](Invoke-Db ("INSERT INTO {0} (tlsloja, {1}, {2}) VALUES ({3}, {4}, '{5}')" -f $TLS_TABLE, $TLS_COL_CAIXA, $TLS_COL_TOKEN, $TLS_LOJA, $script:NumCaixa, (Get-SqlTexto $script:OrigToken)) -SemRetentar)
        }
        [void](Invoke-Db 'COMMIT' -SemRetentar)
        Write-Log ('RESTORE_TOKEN={0}' -f $(if ($script:OrigTokenExiste) { 'original' } else { 'removido' }))
    } catch {
        try { [void](Invoke-Db 'ROLLBACK' -SemRetentar) } catch { }
        Write-Log ('WARN: falha ao restaurar token: {0}' -f $_)
        $falhas += 'token'
    }

    # CONFITLS.INI
    try {
        if ($script:OrigIniExiste -and $script:OrigIniBackup -and (Test-Path -LiteralPath $script:OrigIniBackup)) {
            Copy-Seguro $script:OrigIniBackup $CONFITLS_INI
            Write-Log 'RESTORE_CONFITLS=restaurado'
        } elseif (Test-Path -LiteralPath $CONFITLS_INI) {
            Remove-Item -LiteralPath $CONFITLS_INI -Force
            Write-Log 'RESTORE_CONFITLS=removido'
        }
    } catch {
        Write-Log ('WARN: falha ao restaurar CONFITLS.INI: {0}' -f $_)
        $falhas += 'confitls'
    }

    # Controle TLS nao e restaurado (mesma regra do Linux).
    Write-Log 'RESTORE_CTRL=ignorado_por_regra'
    if ($falhas.Count -gt 0) { Write-Log ('ROLLBACK_RESULT=PARCIAL ({0})' -f ($falhas -join ',')) }
    else { Write-Log 'ROLLBACK_RESULT=COMPLETO' }
}

# +--------------------------------------------------------------------------+
# | CANCELADO PELO OPERADOR
# | O que faz: Quando o operador cancela, desfaz o que foi mudado e encerra.
# | Por quê:   Cancelar nunca pode deixar o PDV configurado pela metade.
# +--------------------------------------------------------------------------+
function Stop-Cancelado {
    Write-Log 'INFO: operação cancelada pelo usuário'
    $restaurou = $false
    if ($script:RollbackOn -and -not $script:SkipRollback) { Invoke-Rollback; $restaurou = $true }
    Close-Progresso
    if ($restaurou) { Show-Mensagem 'Cancelado. A configuração anterior foi restaurada.' 'aviso' }
    else { Show-Mensagem 'Cancelado. Nada foi alterado.' 'aviso' }
    Complete-Log
    Exit-Script 0
}

# Port do die() do Linux: erro fatal fora do menu.
# +--------------------------------------------------------------------------+
# | ERRO GRAVE
# | O que faz: Mostra o erro, desfaz o que estiver pendente, salva o log e
# |            encerra.
# | Por quê:   Erro sem volta precisa terminar com o PDV no estado anterior e
# |            com o motivo registrado.
# +--------------------------------------------------------------------------+
function Stop-ComErro([string]$msg) {
    Write-Log ('ERRO_FATAL: {0}' -f $msg)
    Write-Log ('ERRO_CONTEXTO: ROLLBACK_ENABLED={0} SKIP_ROLLBACK={1}' -f $script:RollbackOn, $script:SkipRollback)
    $tinha = $script:RollbackOn
    Invoke-Rollback
    Close-Progresso
    Show-Mensagem $msg 'erro'
    if ($tinha) { Write-Linhas 'A configuração anterior foi restaurada.' 'Yellow' }
    if ($script:CheckoutFoiFechado) { Write-Linhas 'O Checkout foi fechado para o teste. Abra-o de novo pelo atalho de sempre.' 'Gray' }
    Complete-Log
    Exit-Script 1
}

# =========================================================
# ETAPAS
# =========================================================

# +--------------------------------------------------------------------------+
# | CONFERIR ARQUIVOS DO CHECKOUT
# | O que faz: Confere se existem a pasta do checkout, a CliSiTef, o
# |            IntegracaoDB.ini e a biblioteca do MySQL.
# | Por quê:   Sem eles não há o que configurar; melhor avisar logo no
# |            começo.
# +--------------------------------------------------------------------------+
function Confirm-Arquivos {
    if (-not (Test-Path -LiteralPath $CheckoutDir)) { Stop-ComErro ('Pasta do Checkout não encontrada: ' + $CheckoutDir) }
    if (-not (Test-Path -LiteralPath $SITEF_DLL)) { Stop-ComErro ('CliSiTef não encontrada: ' + $SITEF_DLL) }
    if (-not (Test-Path -LiteralPath $INTEGRACAO_INI)) { Stop-ComErro ('Arquivo não encontrado: ' + $INTEGRACAO_INI) }
    $script:MysqlDll = Find-MysqlDll
    if (-not $script:MysqlDll) { Stop-ComErro ('Biblioteca do MySQL (LIBMYSQL*.DLL) não encontrada em ' + $CheckoutDir) }
    Write-Log ('SITEF_DLL={0}' -f $SITEF_DLL)
    Write-Log ('MYSQL_DLL={0}' -f $script:MysqlDll)
}

# +--------------------------------------------------------------------------+
# | CAIXA FECHADO
# | O que faz: Se o Checkout estiver aberto, pergunta se pode fechar e fecha.
# | Por quê:   O teste usa a mesma CliSiTef do Checkout; com ele aberto, os
# |            dois brigariam.
# +--------------------------------------------------------------------------+
function Confirm-CaixaFechado {
    $procs = @(Get-Process -Name 'Checkout' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Write-Log 'CHECKOUT_EM_EXECUCAO=0'; return $true }
    Write-Log ('CHECKOUT_EM_EXECUCAO={0}' -f $procs.Count)
    if (-not $script:Auto -and -not (Ask-SimNao "O Checkout está aberto e precisa ser fechado para o teste.`r`n`r`nFechar o Checkout agora?")) { return $false }
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch { } }
    for ($i = 0; $i -lt 20; $i++) {
        if (@(Get-Process -Name 'Checkout' -ErrorAction SilentlyContinue).Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    foreach ($p in @(Get-Process -Name 'Checkout' -ErrorAction SilentlyContinue)) {
        Write-Log ('CHECKOUT_KILL pid={0}' -f $p.Id)
        try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { }
    }
    if (@(Get-Process -Name 'Checkout' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Não foi possível fechar o Checkout. Feche-o e tente de novo.' }
    $script:CheckoutFoiFechado = $true
    return $true
}

# +--------------------------------------------------------------------------+
# | NÚMERO DO CAIXA E BANCO
# | O que faz: Lê o número do caixa e os dados de acesso ao banco.
# | Por quê:   O token TLS é gravado por caixa, então precisamos saber qual
# |            é.
# +--------------------------------------------------------------------------+
function Read-DadosPdv {
    $l = @(Get-Content -LiteralPath $INTEGRACAO_INI)
    $caixa = Get-Digitos (Get-Linha $l 5)
    if (-not $caixa) { Stop-ComErro ('Número do caixa não encontrado no ' + $INTEGRACAO_INI + ' (linha 6).') }
    $script:NumCaixa = [string][int64]$caixa
    $script:CnpjIni = Get-Digitos (Get-Linha $l 6)
    Write-Log ('NUM_CAIXA={0}' -f $script:NumCaixa)

    $cfg = Read-ConfigBanco
    if (-not $cfg.Host -or -not $cfg.Banco) { Stop-ComErro ('Dados do banco incompletos em ' + $cfg.Origem) }
    $script:DbHost = $cfg.Host
    $script:DbPorta = $cfg.Porta
    $script:DbUsuario = $cfg.Usuario
    $script:DbSenha = $cfg.Senha
    $script:DbBanco = $cfg.Banco
    $script:LojaChecksup = $cfg.Loja
    Write-Log ('DB_ORIGEM={0}' -f $cfg.Origem)
    Write-Log ('MYSQL_HOST={0} MYSQL_PORT={1} MYSQL_DB={2} MYSQL_USER={3} MYSQL_PASS={4} LOJA={5}' -f $cfg.Host, $cfg.Porta, $cfg.Banco, $cfg.Usuario, '<oculta>', $cfg.Loja)
}

# +--------------------------------------------------------------------------+
# | CONECTAR NO BANCO
# | O que faz: Conecta no MySQL da loja com a senha padrão.
# | Por quê:   É no banco que o token TLS do caixa fica gravado.
# +--------------------------------------------------------------------------+
function Connect-Banco {
    Import-Nativo
    $script:Db = New-Object TlsMyDb -ArgumentList $script:MysqlDll
    $erro = ''
    try {
        $script:Db.Conectar($script:DbHost, [uint32]$script:DbPorta, $script:DbUsuario, $script:DbSenha, $script:DbBanco)
        Write-Log 'MYSQL_CONECTADO=1 (credencial padrão)'
        return
    } catch { $erro = Get-MsgErro $_; Write-Log ('MYSQL_CONEXAO_FALHOU: {0}' -f $erro) }

    Stop-ComErro ("Não foi possível entrar no banco {0} ({1}).`r`nMotivo: {2}" -f $script:DbBanco, $script:DbHost, $erro)
}

# +--------------------------------------------------------------------------+
# | CONFERIR A TABELA DO TLS
# | O que faz: Confere se a tabela pdvtls existe no banco.
# | Por quê:   Sem essa tabela não há onde gravar o token.
# +--------------------------------------------------------------------------+
function Confirm-Estrutura {
    $t = Invoke-Db ("SHOW TABLES LIKE '{0}'" -f $TLS_TABLE) -Escalar
    Write-Log ('MYSQL_TABLE_{0}={1}' -f $TLS_TABLE, $t)
    if ($t -ne $TLS_TABLE) { Stop-ComErro ('A tabela {0} não existe no banco {1}.' -f $TLS_TABLE, $script:DbBanco) }
}

# +--------------------------------------------------------------------------+
# | IDENTIFICAÇÃO DA LOJA
# | O que faz: Monta os dados da loja para a Fiserv: CNPJ, código Fiserv,
# |            terminal e IP do TEF.
# | Por quê:   A Fiserv reconhece o PDV por esses dados; o IP é conferido
# |            para não aceitar valor malicioso.
# +--------------------------------------------------------------------------+
function Read-Identificacao {
    $reg = $null
    if (Test-Path -LiteralPath $PDVCTR_DBF) {
        try { $reg = Read-Dbf $PDVCTR_DBF } catch { Write-Log ('WARN: falha ao ler pdvctr.dbf: {0}' -f $_) }
    } else { Write-Log 'WARN: pdvctr.dbf ausente' }

    $cnpj = ''; $idTef = ''; $ip = ''; $nome = ''
    if ($reg) {
        $cnpj = Get-Digitos $reg['EMPRCGC']
        $idTef = Get-Digitos $reg['CODEMPTEF']
        $ip = $reg['IPSERVTEF']
        $nome = $reg['EMPRNOM']
        Write-Log ('PDVCTR_DBF: EMPRCGC={0} CODEMPTEF={1} IPSERVTEF={2} LOJA={3}' -f $cnpj, $idTef, $ip, $reg['LOJA'])
    }
    if (-not $cnpj) { $cnpj = $script:CnpjIni }
    if (-not $cnpj) { try { $cnpj = Get-Digitos (Invoke-Db 'SELECT ctremprcgc FROM pdvctr LIMIT 1' -Escalar) } catch { } }
    if (-not $idTef) { try { $idTef = Get-Digitos (Invoke-Db 'SELECT ctrcodemptef FROM pdvctr LIMIT 1' -Escalar) } catch { } }
    if (-not $ip) { $ip = '127.0.0.1' }

    if (-not $cnpj) { Stop-ComErro 'CNPJ da loja não encontrado.' }
    if ($cnpj.Length -lt 14) { $cnpj = $cnpj.PadLeft(14, '0') }
    if ($cnpj.Length -ne 14) { Stop-ComErro ('CNPJ inválido: ' + $cnpj) }
    if (-not $idTef) { Stop-ComErro 'Número Fiserv da loja não encontrado (CODEMPTEF no pdvctr).' }
    # O IP vai na linha de comando do teste (processo elevado): aspas ou espaço
    # vindos do pdvctr.dbf injetariam parâmetros (ex.: -Requisitos <exe qualquer>).
    if ($ip.Trim() -notmatch '^[A-Za-z0-9._:;\-]+$') { Stop-ComErro ('IP do SiTef inválido no pdvctr.dbf: ' + ($ip -replace '[^\x20-\x7E]', '?')) }

    $script:CnpjLoja = $cnpj
    $script:IdLojaTef = [string][int64]$idTef
    $script:IpSiTef = $ip.Trim()
    $script:LojaExibicao = ($nome -replace '\s*\(.*$', '' -replace '\s+', ' ').Trim().ToUpper()
    $script:IdTerm = 'CK' + $script:NumCaixa.PadLeft(6, '0')
    $script:IdLojaFmt = $script:IdLojaTef.PadLeft(8, '0')
    $script:ParmsCli = '[ParmsClient=1={0};2={1}]' -f $script:CnpjLoja, $CNPJ_SH_FIX
    Write-Log ('IDTERM={0} IDLOJA={1} PARMS={2} IP_SITEF={3} LOJA_EXIBICAO={4}' -f $script:IdTerm, $script:IdLojaFmt, $script:ParmsCli, $script:IpSiTef, $script:LojaExibicao)
}

# +--------------------------------------------------------------------------+
# | LER O TOKEN ATUAL
# | O que faz: Busca no banco o token TLS gravado para este caixa.
# | Por quê:   Mostrar o token atual e usá-lo no "Testar TLS".
# +--------------------------------------------------------------------------+
function Get-TokenBanco {
    $v = Invoke-Db ('SELECT {0} FROM {1} WHERE tlsloja={2} AND {3}={4} LIMIT 1' -f $TLS_COL_TOKEN, $TLS_TABLE, $TLS_LOJA, $TLS_COL_CAIXA, $script:NumCaixa) -Escalar
    if ($null -eq $v) { return '' }
    return ($v -replace '\s', '')
}

# +--------------------------------------------------------------------------+
# | FOTO DE ANTES
# | O que faz: Guarda uma cópia do token e do CONFITLS.INI como estavam, em
# |            pasta protegida.
# | Por quê:   É essa cópia que permite desfazer tudo se algo der errado.
# +--------------------------------------------------------------------------+
function Save-EstadoOriginal {
    try { $script:OrigToken = Get-TokenBanco }
    catch { throw ('Não foi possível ler o token atual no banco: ' + (Get-MsgErro $_)) }
    $script:OrigTokenExiste = [bool]$script:OrigToken
    Write-Log ('ORIG_TOKEN_EXISTS={0} ORIG_TOKEN={1}' -f $script:OrigTokenExiste, (Get-Mascara $script:OrigToken))

    $script:OrigIniExiste = Test-Path -LiteralPath $CONFITLS_INI
    if ($script:OrigIniExiste) {
        $script:OrigIniBackup = Join-Path $script:TmpDir 'CONFITLS.INI.backup'
        try { Copy-Item -LiteralPath $CONFITLS_INI -Destination $script:OrigIniBackup -Force }
        catch { throw ('Não foi possível copiar o CONFITLS.INI atual: ' + (Get-MsgErro $_)) }
    }
    Write-Log ('ORIG_CONFITLS_EXISTS={0}' -f $script:OrigIniExiste)
    foreach ($c in $CTRL_CANDIDATOS) { Write-Log ('ORIG_CTRL {0} existe={1}' -f $c, (Test-Path -LiteralPath $c)) }

    if (-not $script:OrigIniExiste) { $script:OrigIniBackup = '' }
    $script:RollbackOn = $true
    $script:TokenAtual = $script:OrigToken
}

# +--------------------------------------------------------------------------+
# | LER O CONFITLS.INI
# | O que faz: Lê o arquivo de configuração TLS da CliSiTef.
# | Por quê:   Conferir se ele está correto antes de testar.
# +--------------------------------------------------------------------------+
function Read-ConfiTls {
    $r = @{ Existe = $false; Secao = $false; Tipo = ''; Url = ''; Token = '' }
    if (-not (Test-Path -LiteralPath $CONFITLS_INI)) { return $r }
    $r.Existe = $true
    foreach ($linha in @(Get-Content -LiteralPath $CONFITLS_INI)) {
        $x = ([string]$linha).Trim()
        if ($x -eq '[ConfiguracaoTLS]') { $r.Secao = $true }
        elseif ($x -match '^TipoComunicacaoExterna=(.*)$' -and -not $r.Tipo) { $r.Tipo = ($matches[1] -replace '\s', '') }
        elseif ($x -match '^URLTLS=(.*)$' -and -not $r.Url) { $r.Url = ($matches[1] -replace '\s', '') }
        elseif ($x -match '^TokenRegistro=(.*)$' -and -not $r.Token) { $r.Token = ($matches[1] -replace '\s', '') }
    }
    return $r
}

# +--------------------------------------------------------------------------+
# | GRAVAR O CONFITLS.INI
# | O que faz: Grava o arquivo que liga o modo TLS, com o endereço da Fiserv
# |            e o token.
# | Por quê:   É esse arquivo que faz a CliSiTef usar TLS; sem ele o PDV fica
# |            em GSurf.
# +--------------------------------------------------------------------------+
function Write-ConfiTls {
    $conteudo = "[ConfiguracaoTLS]`r`nTipoComunicacaoExterna=TLSGWP`r`nURLTLS=$URL_TLS`r`nTokenRegistro=$($script:TokenTls)`r`n"
    $tmp = $CONFITLS_INI + '.tmp'
    # CreateNew: um .tmp (ou link) deixado por outro usuário não é seguido nem reaproveitado.
    if ([IO.File]::Exists($tmp)) { [IO.File]::SetAttributes($tmp, [IO.FileAttributes]::Normal); [IO.File]::Delete($tmp) }
    $bytes = [Text.Encoding]::ASCII.GetBytes($conteudo)
    $fs = New-Object IO.FileStream($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    if (Test-Path -LiteralPath $CONFITLS_INI) { Remove-Item -LiteralPath $CONFITLS_INI -Force }
    Move-Item -LiteralPath $tmp -Destination $CONFITLS_INI -Force
    Write-Log ('CONFITLS_INI={0} TOKEN={1}' -f $CONFITLS_INI, (Get-Mascara $script:TokenTls))
}

# +--------------------------------------------------------------------------+
# | GRAVAR O TOKEN NO BANCO
# | O que faz: Apaga o token antigo deste caixa e grava o novo, de uma vez
# |            só.
# | Por quê:   Garante um único token correto por caixa; se falhar no meio,
# |            nada é gravado.
# +--------------------------------------------------------------------------+
function Write-TokenMysql {
    $where = 'tlsloja={0} AND {1}={2}' -f $TLS_LOJA, $TLS_COL_CAIXA, $script:NumCaixa
    $cnt = Invoke-Db ('SELECT COUNT(*) FROM {0} WHERE {1}' -f $TLS_TABLE, $where) -Escalar
    Write-Log ('PDVTLS_COUNT={0}' -f $cnt)
    if ([int]$cnt -gt 1) { Write-Log ('WARN: registros duplicados em pdvtls para caixa {0}' -f $script:NumCaixa) }
    try {
        [void](Invoke-Db 'START TRANSACTION' -SemRetentar)
        [void](Invoke-Db ('DELETE FROM {0} WHERE {1}' -f $TLS_TABLE, $where) -SemRetentar)
        [void](Invoke-Db ("INSERT INTO {0} (tlsloja, {1}, {2}) VALUES ({3}, {4}, '{5}')" -f $TLS_TABLE, $TLS_COL_CAIXA, $TLS_COL_TOKEN, $TLS_LOJA, $script:NumCaixa, $script:TokenTls) -SemRetentar)
        [void](Invoke-Db 'COMMIT' -SemRetentar)
    } catch {
        try { [void](Invoke-Db 'ROLLBACK' -SemRetentar) } catch { }
        throw ('erro ao gravar na tabela pdvtls: ' + $_)
    }
    $v = Invoke-Db ("SELECT COUNT(*) FROM {0} WHERE {1} AND {2}='{3}'" -f $TLS_TABLE, $where, $TLS_COL_TOKEN, $script:TokenTls) -Escalar
    Write-Log ('MYSQL_POST_INSERT_VERIFY_COUNT={0}' -f $v)
    if ([int]$v -lt 1) { throw 'o token não ficou gravado na tabela pdvtls' }
}

# +--------------------------------------------------------------------------+
# | CONFERIR O QUE FOI GRAVADO
# | O que faz: Confere se o token no banco e o CONFITLS.INI estão iguais e
# |            corretos.
# | Por quê:   Só vale testar se a configuração ficou perfeita.
# +--------------------------------------------------------------------------+
function Confirm-Gravacoes {
    $where = 'tlsloja={0} AND {1}={2}' -f $TLS_LOJA, $TLS_COL_CAIXA, $script:NumCaixa
    $cnt = Invoke-Db ("SELECT COUNT(*) FROM {0} WHERE {1} AND {2}='{3}'" -f $TLS_TABLE, $where, $TLS_COL_TOKEN, $script:TokenTls) -Escalar
    Write-Log ('VALIDATE_PDVTLS_COUNT={0}' -f $cnt)
    if ([int]$cnt -lt 1) { throw 'token não encontrado na tabela pdvtls' }
    $c = Read-ConfiTls
    Write-Log ('VALIDATE_CONFITLS existe={0} secao={1} tipo={2} url={3} token={4}' -f $c.Existe, $c.Secao, $c.Tipo, $c.Url, (Get-Mascara $c.Token))
    if (-not $c.Existe) { throw 'o CONFITLS.INI não existe' }
    if (-not $c.Secao) { throw 'CONFITLS.INI sem a seção [ConfiguracaoTLS]' }
    if ($c.Tipo -ne 'TLSGWP') { throw 'CONFITLS.INI com TipoComunicacaoExterna diferente de TLSGWP' }
    if ($c.Url -ne $URL_TLS) { throw ('CONFITLS.INI com URLTLS diferente de ' + $URL_TLS) }
    if ($c.Token -ne $script:TokenTls) { throw 'token do CONFITLS.INI diferente do token do banco' }
}

# +--------------------------------------------------------------------------+
# | ZERAR O CONTROLE DA CLISITEF
# | O que faz: Apaga o arquivo de controle que a CliSiTef cria na primeira
# |            instalação TLS.
# | Por quê:   Com token novo, a CliSiTef precisa se registrar de novo na
# |            Fiserv.
# +--------------------------------------------------------------------------+
function Remove-ControleTls {
    foreach ($c in $CTRL_CANDIDATOS) {
        if (Test-Path -LiteralPath $c) {
            Write-Log ('TLS_CONTROL_REMOVENDO={0}' -f $c)
            Remove-Item -LiteralPath $c -Recurse -Force
            if (Test-Path -LiteralPath $c) { throw ('não foi possível apagar ' + $c) }
        }
    }
}

# +--------------------------------------------------------------------------+
# | LIGAR O MODO GSURF
# | O que faz: Guarda o CONFITLS.INI como backup e o remove.
# | Por quê:   Sem esse arquivo a CliSiTef volta a usar a GSurf; o backup
# |            permite voltar ao TLS.
# +--------------------------------------------------------------------------+
function Switch-Gsurf {
    if (Test-Path -LiteralPath $CONFITLS_INI) {
        Copy-Seguro $CONFITLS_INI $CONFITLS_BKP_INI
        Remove-Item -LiteralPath $CONFITLS_INI -Force
        Write-Log ('CONFITLS_BKP_GERADO={0}' -f $CONFITLS_BKP_INI)
    } else {
        Write-Log 'CONFITLS_INI ausente (já em GSurf)'
    }
    if (Test-Path -LiteralPath $CONFITLS_INI) { throw 'o CONFITLS.INI continua na pasta' }
}

# +--------------------------------------------------------------------------+
# | CÓPIA PROTEGIDA DO SCRIPT
# | O que faz: Escolhe qual cópia do script os processos de teste vão rodar:
# |            a guardada na pasta protegida.
# | Por quê:   Impede que alguém troque o script na pasta pública enquanto
# |            ele roda como administrador.
# +--------------------------------------------------------------------------+
function Get-ScriptFilho {
    if ($script:ScriptFilho) { return $script:ScriptFilho }
    return $script:SelfPath
}

# Roda o teste num PowerShell 32-bit novo (DLL carregada do zero, como o
# restart do servico no Linux). O filho escreve PCT/LOG/RESULT num arquivo.
# +--------------------------------------------------------------------------+
# | RODAR O TESTE E ACOMPANHAR
# | O que faz: Abre o processo de teste escondido e vai mostrando o andamento
# |            até o resultado.
# | Por quê:   Mantém a tela atualizada enquanto a CliSiTef conversa com o
# |            servidor.
# +--------------------------------------------------------------------------+
function Invoke-TesteSiTef([string]$modo, [int]$pctIni, [int]$pctMax) {
    $st = Join-Path $script:TmpDir ('teste_{0}_{1}.txt' -f $modo, (Get-Date -Format 'HHmmssfff'))
    $cn = $st + '.cancelar'
    [IO.File]::WriteAllText($st, '')
    $psExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    # Nenhum valor com aspas na linha de comando do filho elevado (injeção de parâmetro).
    foreach ($v in @($script:IpSiTef, $script:IdLojaFmt, $script:IdTerm, $script:ParmsCli, $CheckoutDir)) {
        if ([string]$v -match '"') { throw 'dado do PDV com aspas; teste não executado' }
    }
    # Filho roda a cópia do script na pasta protegida (o original fica em pasta gravável por todos).
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Teste -Modo {1} -IpSiTef "{2}" -IdLoja "{3}" -IdTerm "{4}" -Parms "{5}" -Status "{6}" -Cancelar "{7}" -PctIni {8} -PctMax {9} -TimeoutSeg {10} -CheckoutDir "{11}"' -f `
        (Get-ScriptFilho), $modo, $script:IpSiTef, $script:IdLojaFmt, $script:IdTerm, $script:ParmsCli, $st, $cn, $pctIni, $pctMax, $TimeoutSeg, $CheckoutDir
    Write-LogSep
    Write-Log ('TESTE_{0}: iniciando processo de teste' -f $modo)

    $psi = New-Object Diagnostics.ProcessStartInfo($psExe, $a)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $CheckoutDir
    $p = [Diagnostics.Process]::Start($psi)
    # Guardados para o Ctrl+C (finally do main) encerrar o teste com Finaliza.
    $script:ProcTeste = $p
    $script:CancelarArq = $cn

    $res = @{ Codigo = -1; Msg = ''; Util = ''; Ultima = ''; Cancelado = $false }
    $lidos = 0
    $fim = $false
    while (-not $fim) {
        $fim = $p.HasExited
        # le linhas novas do arquivo de status
        try {
            $fs = New-Object IO.FileStream($st, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                if ($fs.Length -gt $lidos) {
                    [void]$fs.Seek($lidos, [IO.SeekOrigin]::Begin)
                    $buf = New-Object byte[] ([int]($fs.Length - $lidos))
                    [void]$fs.Read($buf, 0, $buf.Length)
                    $txt = [Text.Encoding]::UTF8.GetString($buf)
                    $ult = $txt.LastIndexOf("`n")
                    if ($ult -ge 0) {
                        $lidos += [Text.Encoding]::UTF8.GetByteCount($txt.Substring(0, $ult + 1))
                        foreach ($linha in ($txt.Substring(0, $ult + 1) -split "`r?`n")) {
                            if (-not $linha) { continue }
                            $pt = $linha.Split('|')
                            if ($pt[0] -eq 'PCT') { Set-Progresso ([int]$pt[1]) $script:Rotulo }
                            elseif ($pt[0] -eq 'LOG') { Write-Log ('SITEF[{0}] {1}' -f $modo, $linha.Substring(4)) }
                            elseif ($pt[0] -eq 'RESULT') {
                                $res.Codigo = [int]$pt[1]
                                if ($pt.Count -gt 2) { $res.Msg = $pt[2] }
                                if ($pt.Count -gt 3) { $res.Util = $pt[3] }
                                if ($pt.Count -gt 4) { $res.Ultima = $pt[4] }
                                Write-Log ('SITEF[{0}] RESULT codigo={1} msg={2}' -f $modo, $res.Codigo, $res.Msg)
                            }
                        }
                    }
                }
            } finally { $fs.Close() }
        } catch { }

        if (-not $fim) { Start-Sleep -Milliseconds 150 }
    }
    $script:ProcTeste = $null
    if ($res.Codigo -eq -1) {
        $res.Codigo = 90
        $res.Msg = 'O teste terminou sem resultado (código {0})' -f $p.ExitCode
        Write-Log $res.Msg
    }
    if ($res.Codigo -eq 99) { $res.Cancelado = $true }
    return $res
}

# =========================================================
# MENU / ACOES
# =========================================================

# TLS = CONFITLS.INI presente em C:\checkout; GSurf = ausente.
# +--------------------------------------------------------------------------+
# | MODO ATUAL
# | O que faz: Diz se o PDV está em TLS (CONFITLS.INI existe) ou GSurf.
# | Por quê:   Mostrar o modo no menu e saber o que manter no fim.
# +--------------------------------------------------------------------------+
function Get-ModoAtual {
    if (Test-Path -LiteralPath $CONFITLS_INI) { return 'TLS' }
    return 'GSURF'
}

# +--------------------------------------------------------------------------+
# | NOME DO MODO
# | O que faz: Escreve o modo como o operador conhece: "TLS" ou "GSurf".
# | Por quê:   Texto amigável na tela.
# +--------------------------------------------------------------------------+
function Get-NomeModo([string]$m) {
    if ($m -eq 'TLS') { return 'TLS' }
    return 'GSurf'
}

# +--------------------------------------------------------------------------+
# | ESPERAR ENTER
# | O que faz: Espera o operador apertar Enter.
# | Por quê:   Dá tempo de ler a mensagem antes de voltar ao menu.
# +--------------------------------------------------------------------------+
function Wait-Enter {
    Write-Host ''
    try { [void](Read-Host '  Enter para continuar') } catch { }
}

# +--------------------------------------------------------------------------+
# | DESENHAR OPÇÃO DO MENU
# | O que faz: Desenha uma opção do menu, destacada se estiver selecionada.
# | Por quê:   O operador vê qual opção vai escolher antes de confirmar.
# +--------------------------------------------------------------------------+
function Write-LinhaMenu([string]$k, [string]$texto, [bool]$sel) {
    $larg = (Get-LarguraTexto) + 2
    if ($sel) {
        Write-Host ' ' -NoNewline
        Write-Host ((' > {0} - {1}' -f $k, $texto).PadRight($larg)) -BackgroundColor DarkCyan -ForegroundColor White
    } else {
        Write-Host '    ' -NoNewline
        Write-Host $k -NoNewline -ForegroundColor Yellow
        Write-Host ((' - ' + $texto).PadRight($larg - 4 - $k.Length + 1)) -ForegroundColor White
    }
}

# +--------------------------------------------------------------------------+
# | RODAPÉ DO MENU
# | O que faz: Mostra "Opção: N" e a dica de uso.
# | Por quê:   Deixa claro que só avança com Enter.
# +--------------------------------------------------------------------------+
function Write-RodapeMenu([string]$k) {
    $larg = (Get-LarguraTexto) + 2
    Write-Host '  Opção: ' -NoNewline -ForegroundColor Cyan
    Write-Host $k -NoNewline -ForegroundColor Yellow
    Write-Host ('   (número ou setas, Enter confirma)'.PadRight($larg - 9 - $k.Length)) -ForegroundColor DarkGray
}

# Menu numerado: @('1:Texto', '2:Texto', '0:Sair') -> devolve a chave escolhida.
# A opção atual fica destacada; número ou seta muda o destaque; Enter confirma.
# +--------------------------------------------------------------------------+
# | MENU COM SELEÇÃO
# | O que faz: Mostra o menu; número ou setas mudam o destaque e só o Enter
# |            confirma.
# | Por quê:   Evita escolher errado por engano: só avança com confirmação.
# +--------------------------------------------------------------------------+
function Ask-Escolha([string[]]$opcoes, [string]$Esc = '') {
    $validas = @()
    $textos = @()
    foreach ($o in $opcoes) {
        $validas += $o.Substring(0, $o.IndexOf(':'))
        $textos += $o.Substring($o.IndexOf(':') + 1)
    }
    $n = $validas.Count
    $sel = 0
    for ($i = 0; $i -lt $n; $i++) { Write-LinhaMenu $validas[$i] $textos[$i] ($i -eq $sel) }
    Write-RodapeMenu $validas[$sel]

    $interativo = $true
    try { $topo = [Console]::CursorTop - ($n + 1); if ($topo -lt 0) { $interativo = $false } } catch { $interativo = $false }
    while ($interativo) {
        try { $tecla = [Console]::ReadKey($true) } catch { $interativo = $false; break }
        if ($tecla.Key -eq 'Enter') {
            Write-Log ('UI_OPCAO={0}' -f $validas[$sel])
            return $validas[$sel]
        }
        if ($Esc -and $tecla.Key -eq 'Escape') {
            Write-Log ('UI_OPCAO={0} (Esc)' -f $Esc)
            return $Esc
        }
        $novo = $sel
        if ($tecla.Key -eq 'UpArrow') { $novo = ($sel - 1 + $n) % $n }
        elseif ($tecla.Key -eq 'DownArrow') { $novo = ($sel + 1) % $n }
        else {
            $idx = [array]::IndexOf($validas, [string]$tecla.KeyChar)
            if ($idx -ge 0) { $novo = $idx }
        }
        if ($novo -ne $sel) {
            $sel = $novo
            [Console]::SetCursorPosition(0, $topo)
            for ($i = 0; $i -lt $n; $i++) { Write-LinhaMenu $validas[$i] $textos[$i] ($i -eq $sel) }
            Write-RodapeMenu $validas[$sel]
        }
    }

    # Sem console interativo (entrada redirecionada): digita e Enter.
    while ($true) {
        $r = ([string](Read-Campo 'Opção:')).Trim()
        if ($validas -contains $r) { Write-Log ('UI_OPCAO={0}' -f $r); return $r }
        Write-Dica 'Digite uma das opções acima.'
    }
}

# +--------------------------------------------------------------------------+
# | TELA DE IDENTIFICAÇÃO
# | O que faz: Mostra loja, caixa, código Fiserv, CNPJ, token e modo atual.
# | Por quê:   O operador confere que está no PDV certo antes de mexer.
# +--------------------------------------------------------------------------+
function Show-Pdv {
    $tk = ''
    try { $tk = Get-TokenBanco } catch { Write-Log ('WARN: falha ao ler token: {0}' -f $_) }
    if (-not $tk) { $tk = 'nenhum' }
    Write-Titulo 'InstalaTLS - PDV Windows'
    Write-Campo 'Loja' $script:LojaExibicao
    Write-Campo 'Caixa' $script:NumCaixa
    Write-Campo 'Fiserv' $script:IdLojaFmt
    Write-Campo 'CNPJ' (Format-Cnpj $script:CnpjLoja)
    Write-Campo 'Token' $tk
    Write-Campo 'Modo atual' (Get-NomeModo (Get-ModoAtual))
    Write-Host ''
}

# Monta o ambiente TLS com o token do banco (recria o CONFITLS.INI se preciso).
# +--------------------------------------------------------------------------+
# | MONTAR O AMBIENTE TLS
# | O que faz: Pega o token do banco, recria o CONFITLS.INI se preciso e
# |            confere tudo.
# | Por quê:   Deixa o PDV pronto para funcionar em TLS.
# +--------------------------------------------------------------------------+
function Mount-Tls {
    $tb = Get-TokenBanco
    if (-not $tb) { throw 'nenhum token cadastrado para este caixa' }
    if ($tb -notmatch $TOKEN_REGEX) { throw 'token do banco fora do formato 0000-0000-0000-0000' }
    $script:TokenTls = $tb
    $c = Read-ConfiTls
    if (-not $c.Existe -or -not $c.Secao -or $c.Tipo -ne 'TLSGWP' -or $c.Url -ne $URL_TLS -or $c.Token -ne $script:TokenTls) {
        Write-Log 'AÇÃO: recriando CONFITLS.INI com conteúdo íntegro'
        Write-ConfiTls
    }
    Confirm-Gravacoes
}

# Inicio de cada acao: zera estado, exige caixa fechado, tira snapshot.
# +--------------------------------------------------------------------------+
# | COMEÇAR UMA AÇÃO
# | O que faz: Zera o estado, garante o caixa fechado, tira a "foto de antes"
# |            e mostra o progresso.
# | Por quê:   Toda ação começa do mesmo jeito seguro, com como desfazer.
# +--------------------------------------------------------------------------+
function Start-Acao([string]$nome, [string]$titulo, [string]$rotulo) {
    Write-LogSep
    Write-Log ('NOVA_ACAO: {0}' -f $nome)
    $script:RollbackOn = $false
    $script:SkipRollback = $false
    $script:TestMsg = ''
    if (-not (Confirm-CaixaFechado)) { return $false }
    Save-EstadoOriginal
    $script:Rotulo = $rotulo
    Start-Progresso $titulo
    return $true
}

# Falha ao montar o ambiente (antes do teste): desfaz e volta ao menu.
# +--------------------------------------------------------------------------+
# | FALHA ANTES DO TESTE
# | O que faz: Desfaz o que a ação mudou, mostra o erro e volta ao menu.
# | Por quê:   Erro na montagem nunca deixa o PDV quebrado.
# +--------------------------------------------------------------------------+
function Invoke-FalhaAcao([string]$msg) {
    Write-Log ('ACAO_FALHOU: {0}' -f $msg)
    $tinha = $script:RollbackOn
    Invoke-Rollback
    Close-Progresso
    Show-Mensagem $msg 'erro'
    if ($tinha) { Write-Linhas 'A configuração anterior foi restaurada.' 'Yellow' }
    Wait-Enter
}

# +--------------------------------------------------------------------------+
# | DICA PARA CADA FALHA DE COMUNICAÇÃO
# | O que faz: Diz, em uma frase, o que conferir quando o teste TLS ou GSurf
# |            falha, conforme a mensagem recebida.
# | Por quê:   O operador sabe o que corrigir sem consultar o suporte.
# +--------------------------------------------------------------------------+
function Get-DicaFalha([string]$modo, [string]$msg) {
    if ($modo -eq 'TLS') {
        if ($msg -match 'recusou|não iniciou|Erro na CliSiTef') { return 'Feche o Checkout e confira a CliSiTef32I.dll em C:\checkout; depois teste de novo.' }
        if ($msg -match 'token|Token|registro|Registro') { return 'Confira o token TLS com a Fiserv e cadastre de novo (opção 1 - Cadastrar TLS).' }
        return 'Confira a internet do PDV e a liberação de saída para tls-prod.fiservapp.com na porta 443; se estiver liberado, confira o token (opção 1).'
    }
    $d = 'Confira se o serviço GSurf (sitef) está rodando e se o certificado foi instalado (opção 2 - Instalar GSurf).'
    if ($msg -match 'conex|Conex|tempo esgotado') { $d += ' ' + $GSURF_FIREWALL }
    return $d
}

# +--------------------------------------------------------------------------+
# | MOSTRAR O RESULTADO
# | O que faz: Mostra se a comunicação deu OK ou falhou (com o motivo e a dica
# |            em amarelo) e abre o menu depois do teste.
# | Por quê:   O operador decide o próximo passo sabendo o resultado.
# +--------------------------------------------------------------------------+
function Show-Resultado([string]$modo, $r) {
    if ($r.Cancelado) { Stop-Cancelado }
    $script:RollbackOn = $false
    $ok = ($r.Codigo -eq 0)
    if ($ok) { $m = 'Servidor Ativo' }
    else {
        if ($modo -eq 'TLS') { $m = $r.Msg; if (-not $m) { $m = $r.Util } }
        else { $m = $r.Util; if (-not $m) { $m = $r.Ultima }; if (-not $m) { $m = $r.Msg } }
        if (-not $m) { $m = 'Sem retorno' }
    }
    $script:TestMsg = $m
    Set-Progresso 100 $script:Rotulo
    Close-Progresso
    Write-Log ('RESULTADO_FINAL: modo={0} ok={1} msg={2}' -f $modo, $ok, $m)
    Write-Titulo ('Resultado | ' + (Get-NomeModo $modo))
    if ($ok) { Show-Mensagem ('Comunicação OK | ' + $m) 'ok' }
    else {
        Show-Mensagem ('Falha no teste de comunicação ' + (Get-NomeModo $modo) + ' | ' + $m) 'erro'
        Write-Linhas (Get-DicaFalha $modo $m) 'Yellow'
    }
    Invoke-PosTeste $modo
}

# +--------------------------------------------------------------------------+
# | DEIXAR NO MODO ESCOLHIDO
# | O que faz: Coloca o PDV em TLS ou GSurf, se ainda não estiver.
# | Por quê:   Garante que o PDV saia no modo escolhido.
# +--------------------------------------------------------------------------+
function Set-ModoFinal([string]$modo) {
    if ((Get-ModoAtual) -eq $modo) { return $true }
    try {
        if ($modo -eq 'TLS') { Write-Dica 'Montando ambiente TLS...'; Mount-Tls }
        else { Write-Dica 'Montando ambiente GSurf...'; Switch-Gsurf }
        return $true
    } catch {
        $e = Get-MsgErro $_
        Write-Log ('MODO_FINAL_FALHOU: modo={0} {1}' -f $modo, $e)
        Show-Mensagem ('Falha ao montar o ambiente {0}: {1}' -f (Get-NomeModo $modo), $e) 'erro'
        return $false
    }
}

# +--------------------------------------------------------------------------+
# | SAÍDA NORMAL
# | O que faz: Mostra o modo final, lembra de reabrir o Checkout, salva o log
# |            e encerra.
# | Por quê:   Fechamento claro e registrado.
# +--------------------------------------------------------------------------+
function Exit-Final {
    Show-Mensagem ('PDV em modo {0}.' -f (Get-NomeModo (Get-ModoAtual))) 'ok'
    if ($script:CheckoutFoiFechado) { Write-Linhas 'O Checkout foi fechado para o teste. Abra-o de novo pelo atalho de sempre.' 'Gray' }
    Complete-Log
    Exit-Script 0
}

# +--------------------------------------------------------------------------+
# | MENU DEPOIS DO TESTE
# | O que faz: Oferece: 1 mudar para o outro modo (testando antes), 2 voltar
# |            ao menu inicial ou 3 deixar como está e sair.
# | Por quê:   Decisão final do operador sobre o modo do PDV.
# +--------------------------------------------------------------------------+
function Invoke-PosTeste([string]$modo) {
    $outro = 'GSURF'
    if ($modo -ne 'TLS') { $outro = 'TLS' }
    while ($true) {
        Write-Host ''
        $e = Ask-Escolha @(('1:Mudar para {0}' -f (Get-NomeModo $outro)), '2:Voltar para o menu inicial', ('3:Deixar como {0} e sair' -f (Get-NomeModo $modo)))
        if ($e -eq '1') { Invoke-Mudar $modo $outro; return }
        if ($e -eq '2') { return }
        if ($e -eq '3') { if (Set-ModoFinal $modo) { Exit-Final } }
    }
}

# +--------------------------------------------------------------------------+
# | MENU FINAL
# | O que faz: Depois de mudar de modo: 1 volta ao menu principal; 2 (ou Esc)
# |            sai.
# | Por quê:   Fechamento rápido depois que o PDV já está no modo certo.
# +--------------------------------------------------------------------------+
function Invoke-MenuFinal {
    Write-Host ''
    $e = Ask-Escolha @('1:Voltar para o menu principal', '2:Sair [ou pressione Esc]') '2'
    if ($e -eq '2') { Exit-Final }
}

# +--------------------------------------------------------------------------+
# | MUDAR DE MODO COM TESTE
# | O que faz: Monta o outro modo e testa na hora. Se passar, avisa que o PDV
# |            está no modo novo. Se falhar, diz onde falhou, dá a dica e
# |            volta sozinho para o modo que estava funcionando.
# | Por quê:   O PDV nunca fica num modo que não comunica.
# +--------------------------------------------------------------------------+
function Invoke-Mudar([string]$de, [string]$para) {
    if (-not (Confirm-CaixaFechado)) { return }
    Write-LogSep
    Write-Log ('MUDAR_MODO: {0} -> {1}' -f $de, $para)
    $script:Rotulo = 'Testando a comunicação ({0})' -f (Get-NomeModo $para)
    Start-Progresso ('Mudar para ' + (Get-NomeModo $para))
    Set-Progresso 10 ('Montando ambiente ' + (Get-NomeModo $para))
    $etapa = ''; $m = ''
    try {
        if ($para -eq 'TLS') { Mount-Tls } else { Switch-Gsurf }
    } catch {
        $etapa = 'montar o ambiente ' + (Get-NomeModo $para)
        $m = Get-MsgErro $_
    }
    if (-not $etapa) {
        $r = Invoke-TesteSiTef $para 20 90
        if ($r.Cancelado) { Stop-Cancelado }
        Set-Progresso 100 $script:Rotulo
        if ($r.Codigo -ne 0) {
            $etapa = 'teste de comunicação ' + (Get-NomeModo $para)
            $m = $r.Util; if (-not $m) { $m = $r.Msg }; if (-not $m) { $m = 'Sem retorno' }
        }
    }
    Close-Progresso
    if (-not $etapa) {
        Write-Log ('RESULTADO_FINAL: modo={0} ok=True (mudanca)' -f $para)
        Show-Mensagem ('PDV em modo de comunicação {0}. Testes realizados com sucesso.' -f (Get-NomeModo $para)) 'ok'
        Invoke-MenuFinal
        return
    }
    Write-Log ('RESULTADO_FINAL: modo={0} ok=False etapa={1} msg={2} (mudanca)' -f $para, $etapa, $m)
    Show-Mensagem ('Falha ao mudar para {0} | Onde: {1} | {2}' -f (Get-NomeModo $para), $etapa, $m) 'erro'
    Write-Linhas (Get-DicaFalha $para $m) 'Yellow'
    if (Set-ModoFinal $de) {
        Show-Mensagem ('PDV mantido em modo de comunicação {0}, que está funcionando.' -f (Get-NomeModo $de)) 'aviso'
    }
    Invoke-MenuFinal
}

# =========================================================
# INSTALAR GSURF (VPN RSA Integrador - Hospedado)
# =========================================================

$GSURF_RAIZ = 'C:\tef'
$GSURF_DIR = Join-Path $GSURF_RAIZ 'VPN RSA Integrador - Hospedado'
$GSURF_FIREWALL = 'Liberar saída no firewall: IPs 187.103.176.0/20 e 189.85.171.160/28, portas UDP-443, TCP-443, TCP-55844 e TCP-55845, e DNS UDP-53 (gsurfnet.com).'

# Pacote da GSurf (SFX do WinRAR que extrai para C:\tef) vem do próprio
# repositório: o PDV não precisa ter nada da GSurf. SHA-256 conferido antes de
# executar (roda como administrador).
$GSURF_PACOTE_URL = 'https://raw.githubusercontent.com/joaofalcone/TLS/main/gsurf/VPN-RSA-Integrador-Hospedado.exe'
$GSURF_PACOTE_SHA = '7e399a6bcd90e2abaec852af17ae75147094608a44e0c8e7bef6908727227d12'

# C:\tef herda do C:\ a permissão de escrita de qualquer usuário: tudo que o
# script executa como administrador dali (exe e as DLLs que ele carrega da
# própria pasta) é conferido pelo SHA-256 do pacote publicado e fica travado
# contra escrita/troca enquanto roda.
$GSURF_ARQUIVOS = @{
    'RequisitosGSurf\RequisitosGSurf.exe'            = '6fa7526444f7db20b260b5b82361b4a0460ee0437c9f2b077f27b7e47950bed6'
    'RequisitosGSurf\msvcp120.dll'                   = 'd672fb07a05fb53cc821da0fde823fdfd46071854fe8c6c5ea83d7450b978ecb'
    'RequisitosGSurf\msvcr120.dll'                   = 'e0305aa54823e6f39d847f8b651b7bd08c085f1dbbcb5c3c1ce1942c0fa1e9fa'
    'GSClient_1.0.0.15\GSurfRSA_Listener_Setup.msi'  = '891630e47fe3f5227017c929dd664d79a1f0eeb85d257cc4b02adde3b317f9fb'
    'GSClient_1.0.0.15\setup.exe'                    = 'bab39e1dc31da4d7b7075c032ad515c4932d74fb73a9a6ae248d134612d9bffc'
    'Certificado_1.0.0.20\InstaladorGSurf.exe'       = '0c39a1f2cc4d14a9ec28b0beeeb51bac621ef68583951355dd233a2eb411b034'
    'Certificado_1.0.0.20\msvcp120.dll'              = '87c42ca155473e4e71857d03497c8cbc28fa8ff7f2c8d72e8a1f39b71078f608'
    'Certificado_1.0.0.20\msvcr120.dll'              = '86e39b5995af0e042fcdaa85fe2aefd7c9ddc7ad65e6327bd5e7058bc3ab615f'
}
$GSURF_REQUISITOS = @('RequisitosGSurf\RequisitosGSurf.exe', 'RequisitosGSurf\msvcp120.dll', 'RequisitosGSurf\msvcr120.dll')
$GSURF_MSI = @('GSClient_1.0.0.15\GSurfRSA_Listener_Setup.msi')
$GSURF_CERTIFICADO = @('Certificado_1.0.0.20\InstaladorGSurf.exe', 'Certificado_1.0.0.20\msvcp120.dll', 'Certificado_1.0.0.20\msvcr120.dll')

# Abre só leitura e sem compartilhar escrita/exclusão (ninguém troca o arquivo
# até Close) e calcula o SHA-256 por esse mesmo handle: sem janela entre conferir e usar.
# +--------------------------------------------------------------------------+
# | ABRIR E TRAVAR ARQUIVO
# | O que faz: Abre um arquivo impedindo que alguém o altere ou apague
# |            enquanto estiver aberto.
# | Por quê:   Garante que o arquivo conferido é o mesmo que será executado.
# +--------------------------------------------------------------------------+
function Open-Travado([string]$arq) {
    return (New-Object IO.FileStream($arq, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
}

# +--------------------------------------------------------------------------+
# | IMPRESSÃO DIGITAL DO ARQUIVO
# | O que faz: Calcula o SHA-256 (uma impressão digital única) do arquivo
# |            aberto.
# | Por quê:   Se um único byte mudar, a impressão digital muda e o script
# |            percebe.
# +--------------------------------------------------------------------------+
function Get-Sha256Fluxo($fs) {
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash($fs)
    return ([BitConverter]::ToString($h) -replace '-', '').ToLower()
}

# +--------------------------------------------------------------------------+
# | SOLTAR OS ARQUIVOS
# | O que faz: Fecha os arquivos que estavam travados.
# | Por quê:   Libera os arquivos depois que não precisam mais de proteção.
# +--------------------------------------------------------------------------+
function Close-Travados($travados) {
    foreach ($fs in @($travados)) { try { if ($fs) { $fs.Close() } } catch { } }
}

# Confere e trava os arquivos; tira da pasta do exe DLL/exe/manifest estranhos
# (o Windows carrega DLL da pasta do exe antes do System32). Falha = 'GSURF_INTEGRIDADE'.
# +--------------------------------------------------------------------------+
# | CONFERIR OS ARQUIVOS DA GSURF
# | O que faz: Abre, trava e confere a impressão digital de cada arquivo da
# |            GSurf; remove arquivos estranhos.
# | Por quê:   Só roda como administrador o que é exatamente o original da
# |            GSurf.
# +--------------------------------------------------------------------------+
function Open-ArquivosGsurf([string[]]$rels) {
    $travados = @()
    try {
        $pastas = @{}
        foreach ($rel in $rels) {
            $arq = Join-Path $GSURF_DIR $rel
            if (-not [IO.File]::Exists($arq)) { throw ('GSURF_INTEGRIDADE ausente ' + $rel) }
            $fs = Open-Travado $arq
            $travados += $fs
            $sha = Get-Sha256Fluxo $fs
            if ($sha -ne $GSURF_ARQUIVOS[$rel]) { throw ('GSURF_INTEGRIDADE sha ' + $rel + ' ' + $sha) }
            $pastas[(Split-Path -Parent $rel)] = $true
        }
        foreach ($sub in @($pastas.Keys)) {
            foreach ($x in [IO.Directory]::GetFileSystemEntries((Join-Path $GSURF_DIR $sub))) {
                $n = [IO.Path]::GetFileName($x)
                if ($n -notmatch '\.(dll|exe|local|manifest)$' -or $GSURF_ARQUIVOS.ContainsKey((Join-Path $sub $n))) { continue }
                Write-Log ('GSURF_ARQUIVO_ESTRANHO_REMOVIDO={0}' -f $x)
                if ([IO.Directory]::Exists($x)) { [IO.Directory]::Delete($x, $false) }
                else { [IO.File]::SetAttributes($x, [IO.FileAttributes]::Normal); [IO.File]::Delete($x) }
            }
        }
    } catch {
        Close-Travados $travados
        throw
    }
    return ,$travados
}

# Arquivos conferidos e travados; ausentes/alterados = baixa e extrai o pacote
# de novo (uma vez por execução) e confere outra vez.
# +--------------------------------------------------------------------------+
# | GARANTIR ARQUIVOS GSURF ÍNTEGROS
# | O que faz: Confere os arquivos da GSurf; se algum estiver alterado ou
# |            faltando, baixa e extrai de novo uma vez.
# | Por quê:   Corrige sozinho uma pasta incompleta ou mexida, sem passo
# |            extra para o operador.
# +--------------------------------------------------------------------------+
function Lock-Gsurf([string[]]$rels) {
    try { return (Open-ArquivosGsurf $rels) }
    catch {
        $e = Get-MsgErro $_
        if ($e -notlike 'GSURF_INTEGRIDADE*') { throw }
        Write-Log $e
        if ($script:GsurfExtraido) { throw ('Os arquivos da GSurf em ' + $GSURF_DIR + ' estão diferentes do esperado e não foram executados.') }
    }
    Expand-PacoteGsurf
    try { return (Open-ArquivosGsurf $rels) }
    catch {
        Write-Log (Get-MsgErro $_)
        throw ('Os arquivos da GSurf em ' + $GSURF_DIR + ' estão diferentes do esperado e não foram executados.')
    }
}

# +--------------------------------------------------------------------------+
# | BAIXAR E EXTRAIR A GSURF
# | O que faz: Baixa o pacote da GSurf deste repositório, confere a impressão
# |            digital e extrai em C:\tef.
# | Por quê:   O PDV não precisa ter nada da GSurf antes; e nada adulterado é
# |            executado.
# +--------------------------------------------------------------------------+
function Expand-PacoteGsurf {
    $script:GsurfExtraido = $true
    # Extração elevada não segue junção plantada em C:\tef (escreveria em outra pasta).
    foreach ($d in @($GSURF_RAIZ, $GSURF_DIR, (Join-Path $GSURF_DIR 'RequisitosGSurf'), (Join-Path $GSURF_DIR 'GSClient_1.0.0.15'), (Join-Path $GSURF_DIR 'Certificado_1.0.0.20'))) {
        if ([IO.Directory]::Exists($d) -and ([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint)) {
            throw ('A pasta {0} é um atalho (junção) e a GSurf não foi extraída. | Apague {0} e rode de novo.' -f $d)
        }
    }
    [string]$pac = Join-Path $script:TmpDir 'VPN-RSA-Integrador-Hospedado.exe'
    Write-Linhas '> Baixando os instaladores da GSurf...' 'Cyan'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch { }
        (New-Object Net.WebClient).DownloadFile($GSURF_PACOTE_URL, $pac)
    } catch {
        throw ('Não foi possível baixar os instaladores da GSurf: {0} | Confira a internet do PDV (acesso a raw.githubusercontent.com).' -f (Get-MsgErro $_))
    }
    # Hash e execução sobre o arquivo travado: não dá para trocá-lo entre conferir e rodar.
    $fs = Open-Travado $pac
    try {
        $sha = Get-Sha256Fluxo $fs
        Write-Log ('GSURF_PACOTE_SHA256={0}' -f $sha)
        if ($sha -ne $GSURF_PACOTE_SHA) {
            $fs.Close()
            Remove-Item -LiteralPath $pac -Force -ErrorAction SilentlyContinue
            throw 'O arquivo baixado da GSurf está diferente do esperado (SHA-256) e não foi executado. | Rode de novo; se repetir, avise o suporte.'
        }
        Write-Linhas ('> Extraindo para ' + $GSURF_RAIZ + '...') 'Cyan'
        $p = Start-Process -FilePath $pac -ArgumentList ('-s -o+ "-d{0}"' -f $GSURF_RAIZ) -Wait -PassThru
    } finally { $fs.Close() }
    Write-Log ('GSURF_PACOTE_RC={0}' -f $p.ExitCode)
    if (-not (Test-Path -LiteralPath $GSURF_DIR)) { throw ('A extração não criou ' + $GSURF_DIR + '.') }
}

# +--------------------------------------------------------------------------+
# | DICA PARA CADA ERRO DE REQUISITO
# | O que faz: Para cada erro do verificador, diz o que liberar no firewall
# |            ou o que conferir.
# | Por quê:   O operador sabe o que pedir ao cliente sem precisar consultar
# |            o manual.
# +--------------------------------------------------------------------------+
function Get-DicaRequisito([string]$erro) {
    if ($erro -match 'fingerprint') {
        $wmi = 'desconhecido'
        try { $wmi = [string](Get-Service -Name Winmgmt -ErrorAction Stop).Status } catch { }
        return ('Verifique o serviço "Instrumentação de Gerenciamento do Windows" (Winmgmt, agora: {0}). Se estiver ativo, pode ser problema no Windows.' -f $wmi)
    }
    if ($erro -match 'DNS') { return 'Liberar DNS UDP-53 (resolução de gsurfnet.com) e conferir o DNS configurado na rede do PDV.' }
    if ($erro -match 'CDP') { return 'Liberar saída TCP-443 para 187.103.176.0/20 e 189.85.171.160/28 (CDP, instalação do certificado).' }
    $alvo = ''
    if ($erro -match '(\d{1,3}(\.\d{1,3}){3}):(\d+)') { $alvo = ' (falhou em {0}:{1})' -f $matches[1], $matches[3] }
    if ($erro -match 'UDP') { return ('Liberar saída UDP-443 para 187.103.176.0/20 e 189.85.171.160/28' + $alvo + '.') }
    if ($erro -match 'TCP') { return ('Liberar saída TCP-55844 e TCP-55845 para 187.103.176.0/20 e 189.85.171.160/28' + $alvo + '.') }
    return $GSURF_FIREWALL
}

# Roda o RequisitosGSurf.exe escondido (região 3), mostra OK/ERRO e a dica em amarelo.
# +--------------------------------------------------------------------------+
# | VERIFICAR REQUISITOS DA GSURF
# | O que faz: Roda o verificador da GSurf escondido e mostra cada teste em
# |            verde (OK) ou vermelho (erro) com a dica em amarelo.
# | Por quê:   Instalar sem a rede liberada não adianta; o verificador mostra
# |            antes o que falta.
# +--------------------------------------------------------------------------+
function Test-RequisitosGsurf {
    $travados = Lock-Gsurf $GSURF_REQUISITOS
    try {
    $exe = Join-Path $GSURF_DIR $GSURF_REQUISITOS[0]
    $dir = Split-Path -Parent $exe
    [string]$saida = Join-Path $dir 'RequisitosGSurf.log'
    Write-Log ('REQUISITOS_EXE={0}' -f $exe)
    Write-Linhas '> Coletando requisitos (pode levar até 1 minuto)...' 'Cyan'

    # Roda no modo -Requisitos deste script (console próprio oculto).
    # [IO.File]: Remove-Item num diretório plantado com esse nome pararia num "Confirmar".
    if ([IO.File]::Exists($saida)) { [IO.File]::SetAttributes($saida, [IO.FileAttributes]::Normal); [IO.File]::Delete($saida) }
    $psExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Requisitos "{1}"' -f (Get-ScriptFilho), $exe
    $p = Start-Process -FilePath $psExe -ArgumentList $a -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(180000)) {
        try { $p.Kill() } catch { }
        Get-Process -Name 'RequisitosGSurf' -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
        Write-Log 'REQUISITOS: tempo esgotado (180 s)'
    }
    } finally { Close-Travados $travados }

    $linhas = @()
    if (Test-Path -LiteralPath $saida) { $linhas = @(Get-Content -LiteralPath $saida) }
    $oks = 0; $erros = 0; $todos = $false; $etapa = ''
    foreach ($l in $linhas) {
        $x = ([string]$l).Trim()
        if ($x) { Write-Log ('REQUISITOS| ' + $x) }
        if ($x -match '^(Tentando|Testando) ') { $etapa = $x; continue }
        if ($x -match '\[\s*(OK|ERRO)\s*\]') { $etapa = '' }
        # Sem ^: a 1a linha vem colada no prompt da região.
        if ($x -match '\[\s*OK\s*\]\s*(.*)$') { $oks++; Write-Linhas ('[ OK ] ' + $matches[1]) 'Green' }
        elseif ($x -match '\[\s*ERRO\s*\]\s*(.*)$') {
            $erros++
            if (-not $script:ReqFalha) { $script:ReqFalha = $matches[1] + ' | ' + (Get-DicaRequisito $matches[1]) }
            Write-Linhas ('[ERRO] ' + $matches[1]) 'Red'
            Write-Linhas ('       ' + (Get-DicaRequisito $matches[1])) 'Yellow'
        }
        elseif ($x -match 'TODOS TESTES FORAM REALIZADOS') { $todos = $true }
    }
    Write-Log ('REQUISITOS_RESULTADO ok={0} erros={1} todos={2}' -f $oks, $erros, $todos)
    if ($erros -gt 0) { return $false }
    if ($etapa -or -not $todos) {
        # Sem resultado da última etapa = o teste parou no meio (ex.: UDP sem resposta).
        if (-not $etapa) { $etapa = 'fim dos testes' }
        Write-Linhas ('[ERRO] Sem resposta em: ' + $etapa) 'Red'
        Write-Linhas ('       ' + (Get-DicaRequisito $etapa)) 'Yellow'
        Write-Log ('REQUISITOS_INCOMPLETO etapa={0}' -f $etapa)
        if (-not $script:ReqFalha) { $script:ReqFalha = 'sem resposta em: ' + $etapa + ' | ' + (Get-DicaRequisito $etapa) }
        return $false
    }
    if ($oks -eq 0) {
        Write-Linhas 'O verificador de requisitos não retornou resultado.' 'Red'
        Write-Linhas 'Rode RequisitosGSurf.exe manualmente para ver a mensagem.' 'Yellow'
        return $false
    }
    return $true
}

# +--------------------------------------------------------------------------+
# | ACHAR O SERVIÇO GSURF
# | O que faz: Procura no Windows o serviço da GSurf já instalado.
# | Por quê:   Se já existe, não instala de novo.
# +--------------------------------------------------------------------------+
function Get-ServicoGsurf {
    try { return @(Get-WmiObject Win32_Service -Filter "PathName LIKE '%GSCliSvc%'")[0] } catch { return $null }
}

# +--------------------------------------------------------------------------+
# | TEM .NET 4?
# | O que faz: Confere se o .NET Framework 4 está instalado.
# | Por quê:   O serviço da GSurf precisa dele; sem ele a instalação
# |            falharia.
# +--------------------------------------------------------------------------+
function Test-NetFx4 {
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4\Full')) {
        try { if ((Get-ItemProperty -LiteralPath $k -ErrorAction Stop).Install -eq 1) { return $true } } catch { }
    }
    return $false
}

# +--------------------------------------------------------------------------+
# | AJUSTAR O INSTALADOR POR DENTRO
# | O que faz: Executa uma alteração dentro de uma cópia do instalador MSI.
# | Por quê:   Usado para fixar o nome do serviço "sitef".
# +--------------------------------------------------------------------------+
function Invoke-MsiSql($db, [string]$sql) {
    $v = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($sql))
    [void]$v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
    [void]$v.GetType().InvokeMember('Close', 'InvokeMethod', $null, $v, $null)
    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v) } catch { }
}

# O MSI (Visual Studio) zera o campo Serviço no modo silencioso; a transform
# fixa "sitef" (IP e Porta ficam em branco, como na instalação manual).
# +--------------------------------------------------------------------------+
# | FIXAR "SITEF" NO INSTALADOR
# | O que faz: Cria um arquivo de ajuste (transform) que preenche o campo
# |            Serviço com "sitef".
# | Por quê:   Em modo silencioso o instalador apagava esse campo; o ajuste
# |            faz ele ficar como na instalação manual.
# +--------------------------------------------------------------------------+
function New-TransformGsurf([string]$msi) {
    $wi = New-Object -ComObject WindowsInstaller.Installer
    # [string]: Join-Path devolve PSObject e o COM recusa (DISP_E_TYPEMISMATCH).
    [string]$copia = Join-Path $script:TmpDir 'gsurf_sitef.msi'
    [string]$mst = Join-Path $script:TmpDir 'gsurf_sitef.mst'
    Copy-Item -LiteralPath $msi -Destination $copia -Force
    Set-ItemProperty -LiteralPath $copia -Name IsReadOnly -Value $false
    $base = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($msi, [int]0))
    $mod = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($copia, [int]1))
    Invoke-MsiSql $mod "UPDATE CustomAction SET Target='sitef' WHERE Action='CustomTextA_SetProperty_EDIT2'"
    [void]$mod.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $mod, $null)
    [void]$mod.GetType().InvokeMember('GenerateTransform', 'InvokeMethod', $null, $mod, @($base, $mst))
    [void]$mod.GetType().InvokeMember('CreateTransformSummaryInfo', 'InvokeMethod', $null, $mod, @($base, $mst, [int]0, [int]0))
    # Solta os bancos (senão o msiexec acha o MSI em uso).
    foreach ($o in @($mod, $base, $wi)) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { } }
    $mod = $null; $base = $null; $wi = $null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    return $mst
}

# +--------------------------------------------------------------------------+
# | INSTALAR O SERVIÇO GSURF
# | O que faz: Instala o serviço GSurf em silêncio (Serviço = sitef, IP e
# |            Porta em branco) e confere se ficou rodando.
# | Por quê:   Faz sozinho o que antes era feito clicando no instalador.
# +--------------------------------------------------------------------------+
function Install-ServicoGsurf {
    $svc = Get-ServicoGsurf
    if ($svc) {
        Write-Log ('GSURF_SERVICO_EXISTENTE={0} estado={1}' -f $svc.Name, $svc.State)
        if ($svc.State -ne 'Running') { Start-Service -Name $svc.Name }
        Write-Linhas ('[ OK ] Serviço GSurf já instalado ({0})' -f $svc.Name) 'Green'
        return
    }
    if (-not (Test-NetFx4)) {
        throw 'O serviço GSurf precisa do .NET Framework 4, que não está instalado. | Instale o .NET Framework 4 (o setup.exe da pasta GSClient instala) e rode de novo.'
    }
    # MSI conferido e travado da transform até o fim do msiexec (roda como SYSTEM).
    $travados = Lock-Gsurf $GSURF_MSI
    try {
        [string]$msi = Join-Path $GSURF_DIR $GSURF_MSI[0]
        Write-Linhas '> Instalando o serviço GSurf...' 'Cyan'
        $mst = New-TransformGsurf $msi
        $log = Join-Path $CheckoutDir 'InstalaGSurf_msi.log'
        # Log antigo (ou link plantado) sai antes: o msiexec elevado não escreve através dele.
        if ([IO.File]::Exists($log)) { [IO.File]::SetAttributes($log, [IO.FileAttributes]::Normal); [IO.File]::Delete($log) }
        $a = '/i "{0}" /qn /norestart TRANSFORMS="{1}" SERVICE=sitef /l*v "{2}"' -f $msi, $mst, $log
        Write-Log ('MSIEXEC {0}' -f $a)
        # msiexec pelo caminho do sistema (API), não por %windir%.
        $p = Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'msiexec.exe') -ArgumentList $a -Wait -PassThru
    } finally { Close-Travados $travados }
    Write-Log ('MSIEXEC_RC={0}' -f $p.ExitCode)
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw ('A instalação do serviço GSurf falhou (código {0}). | Veja o log {1}.' -f $p.ExitCode, $log)
    }
    $svc = Get-ServicoGsurf
    if (-not $svc) { throw ('O serviço GSurf não apareceu depois da instalação. | Veja o log {0}.' -f $log) }
    if ($svc.State -ne 'Running') { try { Start-Service -Name $svc.Name } catch { Write-Log ('WARN: start {0}: {1}' -f $svc.Name, $_) } }
    Write-Log ('GSURF_SERVICO_INSTALADO={0}' -f $svc.Name)
    Write-Linhas ('[ OK ] Serviço GSurf instalado ({0})' -f $svc.Name) 'Green'
}

# O InstaladorGSurf.exe pergunta login, senha e OTP na própria janela.
# +--------------------------------------------------------------------------+
# | INSTALAR O CERTIFICADO GSURF
# | O que faz: Roda o instalador do certificado na mesma janela; ele pede
# |            login, senha e OTP.
# | Por quê:   O certificado identifica a loja na GSurf; só o operador tem
# |            essas credenciais.
# +--------------------------------------------------------------------------+
function Install-CertificadoGsurf {
    $travados = Lock-Gsurf $GSURF_CERTIFICADO
    try {
        $exe = Join-Path $GSURF_DIR $GSURF_CERTIFICADO[0]
        Write-Titulo 'Certificado GSurf'
        Write-Linhas 'Informe login, senha e OTP quando o instalador pedir.' 'Cyan'
        Write-Host ''
        Write-Log ('CERTIFICADO_EXE={0}' -f $exe)
        $p = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -NoNewWindow -Wait -PassThru
    } finally { Close-Travados $travados }
    Write-Log ('CERTIFICADO_RC={0}' -f $p.ExitCode)
    return $p.ExitCode
}

# +--------------------------------------------------------------------------+
# | OPÇÃO 2 - INSTALAR GSURF
# | O que faz: Garante os arquivos, verifica requisitos, instala o serviço e
# |            o certificado, nessa ordem.
# | Por quê:   Junta em uma opção os três passos que eram feitos à mão.
# +--------------------------------------------------------------------------+
function Invoke-InstalarGsurf {
    Write-Titulo 'Instalar GSurf'
    Write-LogSep
    Write-Log 'NOVA_ACAO: instalar_gsurf'
    $script:GsurfExtraido = $false
    if (-not (Test-Path -LiteralPath $GSURF_DIR)) {
        try { Expand-PacoteGsurf }
        catch {
            $partes = (Get-MsgErro $_) -split ' \| '
            Show-Mensagem $partes[0] 'erro'
            if ($partes.Count -gt 1) { Write-Linhas $partes[1] 'Yellow' }
            Wait-Enter
            return
        }
    }

    $reqOk = $false
    try { $reqOk = Test-RequisitosGsurf }
    catch {
        $partes = (Get-MsgErro $_) -split ' \| '
        Show-Mensagem $partes[0] 'erro'
        if ($partes.Count -gt 1) { Write-Linhas $partes[1] 'Yellow' }
        Wait-Enter
        return
    }
    if (-not $reqOk) {
        Show-Mensagem 'Requisitos da GSurf reprovados. Corrija os itens em amarelo e rode de novo.' 'erro'
        Write-Linhas $GSURF_FIREWALL 'Yellow'
        Wait-Enter
        return
    }
    Write-Linhas 'Requisitos aprovados.' 'Green'

    try { Install-ServicoGsurf }
    catch {
        $partes = (Get-MsgErro $_) -split ' \| '
        Show-Mensagem $partes[0] 'erro'
        if ($partes.Count -gt 1) { Write-Linhas $partes[1] 'Yellow' }
        Wait-Enter
        return
    }

    $rc = Install-CertificadoGsurf
    if ($rc -eq 0) {
        Show-Mensagem 'GSurf instalado. Testando a comunicação...' 'ok'
        Invoke-TestarGsurf
        return
    }
    Show-Mensagem ('O instalador do certificado terminou com código {0}.' -f $rc) 'erro'
    Write-Linhas 'Confira a mensagem acima (login, senha ou OTP) e rode Instalar GSurf de novo.' 'Yellow'
    Wait-Enter
}

# +--------------------------------------------------------------------------+
# | OPÇÃO 1 - CADASTRAR TLS
# | O que faz: Pede o token, grava no banco e no CONFITLS.INI, zera o
# |            controle e testa.
# | Por quê:   É a instalação do TLS no caixa, com teste no final.
# +--------------------------------------------------------------------------+
function Invoke-Cadastrar {
    Write-Titulo 'Cadastrar TLS'
    $t = ''
    while ($true) {
        $t = ([string](Read-Campo 'Token (0000-0000-0000-0000) ou Enter para voltar:')) -replace '\s', ''
        if (-not $t) { return }
        Write-Log ('TOKEN_INFORMADO={0}' -f (Get-Mascara $t))
        if ($t -match $TOKEN_REGEX) { break }
        Show-Mensagem 'Token inválido. Use o formato 0000-0000-0000-0000.' 'erro'
    }
    if (-not (Start-Acao 'cadastrar_tls' 'Cadastrar TLS' 'Testando a comunicação (TLS)')) { return }
    $script:TokenTls = $t

    Set-Progresso 15 'Gravando o token no banco'
    try { Write-TokenMysql } catch { throw ('Falha ao gravar o token no banco: ' + (Get-MsgErro $_)) }
    Set-Progresso 22 'Criando o CONFITLS.INI'
    try { Write-ConfiTls } catch { throw ('Falha ao criar o CONFITLS.INI: ' + (Get-MsgErro $_)) }
    Set-Progresso 28 'Conferindo a configuração'
    try { Confirm-Gravacoes; Remove-ControleTls } catch { throw ('Falha ao conferir a configuração TLS: ' + (Get-MsgErro $_)) }
    Set-Progresso 33 'Ambiente TLS pronto'

    $r = Invoke-TesteSiTef 'TLS' 35 85
    Show-Resultado 'TLS' $r
}

# +--------------------------------------------------------------------------+
# | OPÇÃO 3 - TESTAR TLS
# | O que faz: Monta o TLS com o token que já está no banco e testa.
# | Por quê:   Confirma se o TLS deste caixa está funcionando.
# +--------------------------------------------------------------------------+
function Invoke-TestarTls {
    $tk = Get-TokenBanco
    if (-not $tk) {
        Show-Mensagem 'Nenhum token cadastrado para este caixa. Use Cadastrar TLS.' 'erro'
        Wait-Enter
        return
    }
    if (-not (Start-Acao 'testar_tls' 'Testar TLS' 'Testando a comunicação (TLS)')) { return }

    Set-Progresso 8 'Montando ambiente TLS'
    try { Mount-Tls } catch { throw ('Falha ao montar o ambiente TLS: ' + (Get-MsgErro $_)) }
    Set-Progresso 18 'Ambiente TLS pronto'

    $r = Invoke-TesteSiTef 'TLS' 20 85
    Show-Resultado 'TLS' $r
}

# +--------------------------------------------------------------------------+
# | OPÇÃO 4 - TESTAR GSURF
# | O que faz: Coloca o PDV em GSurf e testa.
# | Por quê:   Confirma se a GSurf deste caixa está funcionando.
# +--------------------------------------------------------------------------+
function Invoke-TestarGsurf {
    if (-not (Start-Acao 'testar_gsurf' 'Testar GSurf' 'Testando a comunicação (GSurf)')) { return }

    Set-Progresso 10 'Montando ambiente GSurf'
    try { Switch-Gsurf } catch { throw ('Falha ao montar o ambiente GSurf: ' + (Get-MsgErro $_)) }
    Set-Progresso 18 'Ambiente GSurf pronto'

    $r = Invoke-TesteSiTef 'GSURF' 20 95
    Show-Resultado 'GSURF' $r
}

# =========================================================
# MAIN
# =========================================================


# =========================================================
# MODO AUTOMÁTICO (TLS + GSurf de uma vez)
# =========================================================

# +--------------------------------------------------------------------------+
# | LER SENHA SEM MOSTRAR
# | O que faz: Lê o que o operador digita sem mostrar na tela (asteriscos).
# | Por quê:   O PIN não pode aparecer na tela nem no histórico.
# +--------------------------------------------------------------------------+
function Read-Senha([string]$rotulo) {
    Write-Host ('  ' + $rotulo + ' ') -NoNewline -ForegroundColor Cyan
    $seg = Read-Host -AsSecureString
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seg)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

# +--------------------------------------------------------------------------+
# | ABRIR A CREDENCIAL DA GSURF COM O PIN
# | O que faz: Decifra (AES-256 com chave tirada do PIN) o login e a senha da
# |            GSurf que vêm cifrados no atalho.
# | Por quê:   Login e senha nunca ficam abertos em lugar nenhum; sem o PIN
# |            certo o bloco cifrado não revela nada. Formato igual ao do
# |            "openssl enc -aes-256-cbc -pbkdf2 -md sha1" (o Linux usa o mesmo).
# +--------------------------------------------------------------------------+
function Unprotect-CredAuto([string]$b64, [string]$pin) {
    $d = [Convert]::FromBase64String($b64)
    if ($d.Length -lt 32 -or [Text.Encoding]::ASCII.GetString($d, 0, 8) -ne 'Salted__') { throw 'credencial inválida' }
    $salt = New-Object byte[] 8
    [Array]::Copy($d, 8, $salt, 0, 8)
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($pin, $salt, $AUTO_ITER)
    $aes = New-Object Security.Cryptography.RijndaelManaged
    $aes.KeySize = 256; $aes.BlockSize = 128
    $aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $kdf.GetBytes(32); $aes.IV = $kdf.GetBytes(16)
    $dec = $aes.CreateDecryptor()
    $txt = [Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($d, 16, $d.Length - 16))
    # 1a linha "TLS1" é a marca: PIN errado que por acaso "decifre" vira lixo sem ela.
    $l = $txt -split "`n"
    if ($l.Count -lt 3 -or $l[0] -ne 'TLS1' -or -not $l[1] -or -not $l[2]) { throw 'credencial inválida' }
    # 4a linha (opcional): senha do root do banco, usada quando o Checksup.ini não tem usuário.
    $root = ''
    if ($l.Count -ge 4) { $root = $l[3] }
    return @{ Login = $l[1]; Senha = $l[2]; Root = $root }
}

# +--------------------------------------------------------------------------+
# | CERTIFICADO GSURF SEM PERGUNTAS
# | O que faz: Roda o instalador do certificado num console oculto e digita
# |            login, senha e OTP por ele. A credencial passa por um arquivo na
# |            pasta protegida, que o processo filho apaga ao ler.
# | Por quê:   Nada de credencial na linha de comando (visível a outros
# |            programas) nem na tela.
# +--------------------------------------------------------------------------+
function Install-CertificadoGsurfAuto([string]$login, [string]$senha, [string]$otp) {
    $travados = Lock-Gsurf $GSURF_CERTIFICADO
    [string]$arq = Join-Path $script:TmpDir ('c_' + [Guid]::NewGuid().ToString('N'))
    [string]$st = Join-Path $script:TmpDir ('s_' + [Guid]::NewGuid().ToString('N'))
    $rc = 97
    try {
        $exe = Join-Path $GSURF_DIR $GSURF_CERTIFICADO[0]
        [IO.File]::WriteAllLines($arq, [string[]]@($login, $senha, $otp))
        $psExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Certificado "{1}" -CredArq "{2}" -Status "{3}"' -f (Get-ScriptFilho), $exe, $arq, $st
        $p = Start-Process -FilePath $psExe -ArgumentList $a -WindowStyle Hidden -PassThru
        if ($p.WaitForExit(200000)) { $rc = $p.ExitCode } else { try { $p.Kill() } catch { }; $rc = 98 }
    } finally {
        Close-Travados $travados
        if ([IO.File]::Exists($arq)) { [IO.File]::Delete($arq) }
    }
    $tela = ''
    if ([IO.File]::Exists($st)) { $tela = [IO.File]::ReadAllText($st); [IO.File]::Delete($st) }
    Write-Log ('CERTIFICADO_AUTO_RC={0}' -f $rc)
    return @{ Rc = $rc; Tela = $tela }
}

# +--------------------------------------------------------------------------+
# | PEDIR O PIN E ABRIR A CREDENCIAL
# | O que faz: Pede o PIN (até 3 vezes) e abre o bloco cifrado do atalho:
# |            login e senha da GSurf e a senha do root do banco.
# | Por quê:   É a primeira coisa do modo automático, porque a senha do root
# |            é usada para conectar no banco quando o Checksup.ini não tem
# |            usuário.
# +--------------------------------------------------------------------------+
function Open-CredAuto {
    $script:Auto = $true
    Write-Host ''
    Write-Host '  InstalaTLS - automático (GSurf + TLS)' -ForegroundColor White
    Write-Host '  > Abrindo as credenciais...' -ForegroundColor Gray
    # Nome diferente de $Cred: no PowerShell maiúscula/minúscula é a mesma variável.
    $script:CredAberta = $null
    # Bloco gerado sem PIN (uso pessoal): abre direto, sem perguntar nada.
    try { $script:CredAberta = Unprotect-CredAuto $Cred '' } catch { }
    for ($t = 1; $t -le 3 -and -not $script:CredAberta; $t++) {
        $pin = Read-Senha 'PIN:'
        try { $script:CredAberta = Unprotect-CredAuto $Cred $pin } catch { Write-Log ('PIN_RECUSADO: ' + (Get-MsgErro $_)); Write-Host '  PIN incorreto.' -ForegroundColor Red }
        $pin = $null
    }
    if (-not $script:CredAberta) { Write-Host '  ERRO: PIN incorreto 3 vezes.' -ForegroundColor Red; Complete-Log; Exit-Script 1 }
}

# +--------------------------------------------------------------------------+
# | MODO AUTOMÁTICO
# | O que faz: Pede PIN e token, instala GSurf (requisitos, serviço e
# |            certificado; pede o OTP na hora do certificado para não
# |            vencer), instala TLS, testa os dois e deixa em GSurf. Mostra só
# |            OK ou ERRO com o local e a dica.
# | Por quê:   Instalação completa em uma tacada, sem menus.
# +--------------------------------------------------------------------------+
function Invoke-Automatico {
    # O PIN já foi pedido em Open-CredAuto (antes do banco: a senha do root vem dele).
    $credAberta = $script:CredAberta
    $tok = ''
    while ($tok -notmatch $TOKEN_REGEX) {
        $tok = ([string](Read-Campo 'Token TLS (0000-0000-0000-0000):')) -replace '\s', ''
        if ($tok -notmatch $TOKEN_REGEX) { Write-Host '  Token inválido.' -ForegroundColor Red }
    }

    $script:Quieto = $true
    $script:Rotulo = 'Instalando'
    Start-Progresso 'auto'
    $falhas = @()
    $gsurfOk = $false

    # 1) GSurf: arquivos, requisitos, serviço e certificado.
    try {
        Set-Progresso 3 'GSurf: preparando arquivos'
        if (-not (Test-Path -LiteralPath $GSURF_DIR)) { Expand-PacoteGsurf }
        Set-Progresso 8 'GSurf: verificando requisitos'
        $script:ReqFalha = ''
        if (-not (Test-RequisitosGsurf)) { throw ('requisitos | ' + $script:ReqFalha) }
        Set-Progresso 20 'GSurf: instalando o serviço'
        Install-ServicoGsurf
        Clear-Barra
        $otp = ''
        while (-not $otp) { $otp = ([string](Read-Campo 'OTP GSurf:')).Trim() }
        Set-Progresso 30 'GSurf: instalando o certificado'
        $c = Install-CertificadoGsurfAuto $credAberta.Login $credAberta.Senha $otp
        $otp = $null
        if ($c.Rc -ne 0 -and $c.Tela -notmatch '(?i)sucesso') {
            $fim = @(($c.Tela -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' / '
            throw ('certificado | {0} (código {1}) | Confira o OTP (vence em segundos) e rode de novo.' -f $fim, $c.Rc)
        }
        $gsurfOk = $true
    } catch {
        # Mensagem "etapa | detalhe | dica" (ou "detalhe | dica"). Parênteses em cada
        # item: no PowerShell a vírgula se junta antes do "+".
        $p = @((Get-MsgErro $_) -split ' \| ')
        if ($p.Count -ge 3) { $falhas += ,@(('GSurf - ' + $p[0] + ': ' + $p[1]), $p[2]) }
        elseif ($p.Count -eq 2) { $falhas += ,@(('GSurf - instalação: ' + $p[0]), $p[1]) }
        else { $falhas += ,@(('GSurf - instalação: ' + $p[0]), '') }
    }
    $credAberta = $null
    $script:CredAberta = $null

    # 2) TLS: token, CONFITLS.INI, controle e teste.
    $tlsOk = $false
    try {
        Set-Progresso 45 'TLS: gravando o token'
        [void](Confirm-CaixaFechado)
        Save-EstadoOriginal
        $script:TokenTls = $tok
        Write-TokenMysql
        Write-ConfiTls
        Confirm-Gravacoes
        Remove-ControleTls
        $script:RollbackOn = $false
        $script:Rotulo = 'TLS: testando a comunicação'
        $r = Invoke-TesteSiTef 'TLS' 50 70
        if ($r.Codigo -eq 0) { $tlsOk = $true }
        else {
            $m = $r.Msg; if (-not $m) { $m = $r.Util }; if (-not $m) { $m = 'Sem retorno' }
            $falhas += ,@(('TLS - teste de comunicação: ' + $m), (Get-DicaFalha 'TLS' $m))
        }
    } catch {
        $e = Get-MsgErro $_
        Invoke-Rollback
        $falhas += ,@(('TLS - instalação: ' + $e), 'A configuração TLS anterior foi restaurada.')
    }

    # 3) GSurf: modo GSurf e teste.
    $gsurfTesteOk = $false
    if ($gsurfOk) {
        try {
            Set-Progresso 75 'GSurf: testando a comunicação'
            Switch-Gsurf
            $script:Rotulo = 'GSurf: testando a comunicação'
            $r = Invoke-TesteSiTef 'GSURF' 78 98
            if ($r.Codigo -eq 0) { $gsurfTesteOk = $true }
            else {
                $m = $r.Util; if (-not $m) { $m = $r.Msg }; if (-not $m) { $m = 'Sem retorno' }
                $falhas += ,@(('GSurf - teste de comunicação: ' + $m), (Get-DicaFalha 'GSURF' $m))
            }
        } catch { $falhas += ,@(('GSurf - modo GSurf: ' + (Get-MsgErro $_)), '') }
    }

    # Fica em GSurf se GSurf comunica; senão em TLS se TLS comunica.
    if (-not $gsurfTesteOk -and $tlsOk) { try { Mount-Tls } catch { } }
    Set-Progresso 100 'Concluído'
    Close-Progresso
    $script:Quieto = $false

    Write-Host ''
    if ($falhas.Count -eq 0) {
        Write-Host '  OK - GSurf e TLS instalados e testados. PDV em modo GSurf.' -ForegroundColor Green
    } else {
        foreach ($f in $falhas) {
            Write-Host ('  ERRO em ' + $f[0]) -ForegroundColor Red
            if ($f[1]) { Write-Host ('  ' + $f[1]) -ForegroundColor Yellow }
        }
        Write-Host ('  PDV em modo {0}.' -f (Get-NomeModo (Get-ModoAtual))) -ForegroundColor White
    }
    foreach ($f in $falhas) { Write-Log ('AUTO_FALHA: {0} | {1}' -f $f[0], $f[1]) }
    if ($script:CheckoutFoiFechado) { Write-Host '  Abra o Checkout de novo pelo atalho de sempre.' -ForegroundColor Gray }
    Complete-Log
    if ($falhas.Count -eq 0) { Exit-Script 0 }
    Exit-Script 1
}

# +--------------------------------------------------------------------------+
# | INÍCIO E MENU PRINCIPAL
# | O que faz: Lê os dados do PDV, conecta no banco e mostra o menu até o
# |            operador sair.
# | Por quê:   É o "roteiro" do script: tudo começa aqui.
# +--------------------------------------------------------------------------+
function Invoke-Principal {
    Write-LogSep
    Write-Log 'INICIO DA EXECUÇÃO DO INSTALATLS (Windows)'
    Write-Log ('SCRIPT={0}' -f $script:SelfPath)
    Write-Log ('CHECKOUT_DIR={0}' -f $CheckoutDir)
    Write-Log ('USUARIO_EXECUCAO={0}' -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    Write-Log ('PS_VERSION={0} PROCESSO_32BIT={1}' -f $PSVersionTable.PSVersion, ([IntPtr]::Size -eq 4))
    Write-Log ('CHECKSUP_INI={0}' -f $script:ChecksupIniUsado)

    if ($Auto) { Open-CredAuto }
    Write-Dica 'Lendo dados do PDV...'
    Confirm-Arquivos
    Read-DadosPdv
    Connect-Banco
    Confirm-Estrutura
    Read-Identificacao

    if ($Auto) { Invoke-Automatico }

    while ($true) {
        Show-Pdv
        $op = Ask-Escolha @('1:Cadastrar TLS', '2:Instalar GSurf', '3:Testar TLS', '4:Testar GSurf', '0:Sair')
        if ($op -eq '0') { Exit-Final }
        try {
            if ($op -eq '1') { Invoke-Cadastrar }
            elseif ($op -eq '2') { Invoke-InstalarGsurf }
            elseif ($op -eq '3') { Invoke-TestarTls }
            elseif ($op -eq '4') { Invoke-TestarGsurf }
        } catch {
            Invoke-FalhaAcao (Get-MsgErro $_)
        }
    }
}

# +--------------------------------------------------------------------------+
# | COMEÇO DA EXECUÇÃO
# | O que faz: Reabre como administrador se preciso, cria a pasta de
# |            trabalho, impede duas janelas ao mesmo tempo e chama o menu.
# |            Se apertar Ctrl+C, desfaz o que estava pendente.
# | Por quê:   Garante que só uma execução mexe no PDV por vez e que
# |            interromper nunca deixa nada pela metade.
# +--------------------------------------------------------------------------+
Confirm-Ambiente

$script:ChecksupIniUsado = $ChecksupIni
if (-not $script:ChecksupIniUsado) { $script:ChecksupIniUsado = Find-ChecksupIni }

$novo = $false
$script:Mutex = New-Object Threading.Mutex($true, 'Global\InstalaTLS', [ref]$novo)
try { $Host.UI.RawUI.WindowTitle = 'InstalaTLS' } catch { }

if (-not $novo) {
    Write-Host 'O InstalaTLS já está aberto em outra janela.' -ForegroundColor Red
    try { [void](Read-Host 'Pressione Enter para fechar') } catch { }
    exit 1
}

Write-Host ''
Write-Host '  InstalaTLS - PDV Windows' -ForegroundColor White
Write-Dica ('Checkout: {0}' -f $CheckoutDir)
Write-Dica 'Ctrl+C cancela a qualquer momento.'
try { Import-Nativo; [TlsNat]::VigiarFechamento() } catch { }

# Temporários (backup do CONFITLS.INI com token, status do teste, pacote/MSI/MST
# da GSurf executados como administrador): nome aleatório (não dá para plantar
# antes) dentro da pasta protegida; sem ela, em %TEMP% com ACL só de administradores.
$seg = Get-PastaSegura
if ($seg) {
    # Sobras de uma janela fechada no X (sai na hora, sem limpar). A trava acima
    # garante que nenhuma outra execução está usando essas pastas.
    foreach ($velha in @(Get-ChildItem -LiteralPath $seg -Filter 'run_*' -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $velha.FullName -Recurse -Force -ErrorAction Stop } catch { }
    }
    $script:TmpDir = Join-Path $seg ('run_' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:TmpDir)
} else {
    $script:TmpDir = Join-Path $env:TEMP ('InstalaTLS_' + [Guid]::NewGuid().ToString('N'))
    $criada = $false
    if (Test-Admin) { try { [void][IO.Directory]::CreateDirectory($script:TmpDir, (New-AclSegura)); $criada = $true } catch { } }
    if (-not $criada) { [void][IO.Directory]::CreateDirectory($script:TmpDir) }
}
# Os filhos elevados (-Teste/-Requisitos) rodam esta cópia: o TLS.ps1 original fica
# em pasta gravável por qualquer usuário e seria relido a cada teste.
$script:ScriptFilho = ''
try {
    $copia = Join-Path $script:TmpDir 'TLS.ps1'
    [IO.File]::Copy($script:SelfPath, $copia, $false)
    $script:ScriptFilho = $copia
} catch { }
$script:Audit = Join-Path $script:TmpDir 'audit.log'
$script:RollbackOn = $false
$script:SkipRollback = $false
$script:LogSalvo = $false
$script:CancelarPedido = $false
$script:CheckoutFoiFechado = $false
$script:TestMsg = ''
$script:ProgressoAtivo = $false
$script:Saindo = $false

try {
    Invoke-Principal
    Exit-Script 0
} catch {
    $e = Get-MsgErro $_
    Write-Log ('EXCECAO_NAO_TRATADA: {0}' -f $e)
    Stop-ComErro ('Erro inesperado: ' + $e)
} finally {
    # Ctrl+C: o PowerShell interrompe e cai aqui sem passar pelo Exit-Script.
    if (-not $script:Saindo) {
        Write-Log 'SINAL: interrupção (Ctrl+C)'
        try { Close-Progresso } catch { }
        Write-Host ''
        Write-Faixa 'CANCELADO' 'DarkYellow' 'Black'
        # Teste em andamento: pede Finaliza a CliSiTef; encerra se nao responder.
        $pt = $script:ProcTeste
        if ($pt -and -not $pt.HasExited) {
            Write-Linhas 'Encerrando o teste de comunicação...' 'Yellow'
            try { [IO.File]::WriteAllText($script:CancelarArq, '1') } catch { }
            try { if (-not $pt.WaitForExit(15000)) { $pt.Kill(); Write-Log 'TESTE: processo encerrado à força' } } catch { }
        }
        if ($script:RollbackOn -and -not $script:SkipRollback) {
            Invoke-Rollback
            Write-Linhas 'A configuração anterior foi restaurada.' 'Yellow'
        } elseif ($script:SkipRollback) {
            Write-Linhas 'A configuração TLS gravada foi mantida.' 'Yellow'
        } else {
            Write-Linhas 'Nada foi alterado.' 'Yellow'
        }
        if (-not $script:LogSalvo) {
            try { Copy-Seguro $script:Audit $FINAL_LOG_FILE; Write-Linhas ('Log salvo em ' + $FINAL_LOG_FILE) 'Gray' } catch { }
        }
        if ($script:CheckoutFoiFechado) { Write-Linhas 'Abra o Checkout de novo pelo atalho de sempre.' 'Gray' }
        try { if ($script:Db) { $script:Db.Fechar() } } catch { }
        if ($script:TmpDir -and (Test-Path -LiteralPath $script:TmpDir)) { try { Remove-Item -LiteralPath $script:TmpDir -Recurse -Force } catch { } }
        try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Close() } } catch { }
        # Janela fecha sozinha ao sair: da tempo de ler o aviso.
        Write-Dica 'Esta janela fecha em 10 segundos.'
        try { Start-Sleep -Seconds 10 } catch { }
    }
}
