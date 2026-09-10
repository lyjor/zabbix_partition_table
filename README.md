# Particionamento de tabelas do Zabbix

O arquivo `zbx_partition.sh` cria e mantém partições por intervalo (`PARTITION BY RANGE`) nas tabelas de histórico e tendências do Zabbix usando MySQL ou MariaDB.

O particionamento é baseado na coluna `clock`, que armazena o horário de cada registro como timestamp Unix.

## Objetivos do script

O script automatiza quatro tarefas:

- converter uma tabela existente para particionamento por intervalo;
- criar partições futuras;
- remover partições mais antigas que o período de retenção;
- consultar o estado atual das partições.

As operações são feitas diretamente no banco configurado por meio do cliente `mysql`.

## Pré-requisitos

No servidor Linux onde o script será executado, instale:

```bash
sudo apt-get update
sudo apt-get install -y bash coreutils mysql-client
```

Em servidores que usam MariaDB, o pacote do cliente pode ser:

```bash
sudo apt-get install -y mariadb-client
```

O servidor precisa conseguir alcançar o banco na porta configurada. Neste projeto, os valores padrão são:

```text
Host:     192.168.68.241
Porta:    3306
Usuário:  lyjor
Banco:    zabbix
```

A senha atualmente está definida no próprio script como `debian`. Gravar senhas no código não é recomendado para produção. O ideal é remover a senha do script e fornecer `ZBX_DB_PASS` por um arquivo protegido ou por outro mecanismo seguro de credenciais.

O usuário do banco precisa ter permissões suficientes para consultar as tabelas e executar `ALTER TABLE`. Um exemplo de concessão, que deve ser avaliado conforme a política de segurança do ambiente, é:

```sql
GRANT SELECT, ALTER, CREATE, DROP ON zabbix.* TO 'lyjor'@'%';
FLUSH PRIVILEGES;
```

A operação de remoção de partições é destrutiva. Uma partição removida não pode ser recuperada sem backup.

## Configuração de acesso ao banco

A configuração fica no início do arquivo `zbx_partition.sh`:

```bash
DB_HOST="${ZBX_DB_HOST:-192.168.68.241}"
DB_PORT="${ZBX_DB_PORT:-3306}"
DB_USER="${ZBX_DB_USER:-lyjor}"
DB_PASS="${ZBX_DB_PASS:-debian}"
DB_NAME="${ZBX_DB_NAME:-zabbix}"
```

O formato `${VARIAVEL:-valor}` significa que o script usa a variável de ambiente quando ela existe; caso contrário, usa o valor padrão informado depois dos dois-pontos.

Assim, é possível sobrescrever a configuração sem editar o script:

```bash
ZBX_DB_HOST=192.168.68.241 \
ZBX_DB_PORT=3306 \
ZBX_DB_USER=lyjor \
ZBX_DB_PASS=debian \
ZBX_DB_NAME=zabbix \
./zbx_partition.sh status --table history
```

## Parâmetros globais

| Parâmetro | Função |
|---|---|
| `--host` | Host do MySQL ou MariaDB. |
| `--port` | Porta do banco, normalmente `3306`. |
| `--user` | Usuário do banco. |
| `--password` | Senha do banco. Evite expor a senha na linha de comando. |
| `--database` | Nome do banco, por padrão `zabbix`. |
| `--yes` | Confirma automaticamente uma operação que pediria confirmação. |
| `--dry-run` | Mostra o SQL que seria executado sem executar o `ALTER TABLE`. |
| `--force` | Permite recriar o particionamento no `init`. É uma operação potencialmente destrutiva e deve ser evitada. |

## Períodos e retenção

O parâmetro `--period` aceita:

- `day`: uma partição por dia e retenção informada em dias;
- `month`: uma partição por mês e retenção informada em meses.

Para a tabela `history`, o padrão recomendado é:

```text
period: day
retention: 60 dias
```

O parâmetro `--future` determina quantas unidades de tempo serão criadas além da data atual. Para `--period day --future 3`, o script mantém partições futuras para os próximos três dias.

O parâmetro `--retention` não cria partições. Ele só é usado pelos comandos `drop-old` e `maintain` para determinar quais partições antigas devem ser removidas.

## Comandos disponíveis

### `init`

Inicializa uma tabela ainda não particionada:

```bash
./zbx_partition.sh init \
  --table history \
  --period day \
  --future 3 \
  --yes
```

O comportamento é:

1. verifica se a tabela existe;
2. verifica se a tabela já possui partições;
3. identifica o menor valor de `clock` existente;
4. gera uma partição por dia desde essa data até a data atual mais a margem de `--future`;
5. executa `ALTER TABLE ... PARTITION BY RANGE (clock)`.

Se a tabela estiver vazia, é obrigatório informar uma data inicial:

```bash
./zbx_partition.sh init \
  --table history \
  --period day \
  --start 2026-01-01 \
  --future 3 \
  --yes
```

O `init` deve ser executado apenas uma vez por tabela. Depois que a tabela estiver particionada, use `add-partition` ou `maintain`.

### `add-partition`

Adiciona as partições futuras que estiverem faltando:

```bash
./zbx_partition.sh add-partition \
  --table history \
  --period day \
  --future 3 \
  --yes
```

O comando consulta o limite da última partição e cria novas partições até a data atual mais a margem futura. Ele não remove dados antigos.

### `drop-old`

Remove as partições mais antigas que o período informado:

```bash
./zbx_partition.sh drop-old \
  --table history \
  --period day \
  --retention 60 \
  --yes
```

Para retenção diária, o script calcula uma data de corte equivalente a hoje menos o número de dias indicado. Depois localiza as partições cujo limite seja menor ou igual ao corte e executa um SQL semelhante a:

```sql
ALTER TABLE `history` DROP PARTITION p2026_07_10, p2026_07_11;
```

Essa operação remove todos os registros contidos nessas partições.

### `maintain`

É o comando recomendado para a manutenção automática de uma tabela:

```bash
./zbx_partition.sh maintain \
  --table history \
  --period day \
  --future 3 \
  --retention 60 \
  --yes
```

O comando executa, nesta ordem:

1. `add-partition`, para garantir as partições futuras;
2. `drop-old`, para remover as partições fora da retenção.

A manutenção deve ser executada diariamente ou com frequência maior. O valor de `--future` deve ser maior que o intervalo máximo esperado entre duas execuções.

### `status`

Consulta o estado de uma tabela sem modificar o banco:

```bash
./zbx_partition.sh status --table history
```

Exemplo de resposta quando ainda não existe particionamento:

```text
history: NAO particionada.
```

### `maintain-all`

Mantém todas as tabelas configuradas no bloco `DEFAULT_TABLE_CONFIG`:

```bash
./zbx_partition.sh maintain-all \
  --retention-history 60 \
  --retention-trends 12 \
  --yes
```

Por padrão, o script considera:

| Tabelas | Período | Retenção padrão |
|---|---:|---:|
| `history`, `history_log`, `history_str`, `history_text`, `history_uint`, `history_bin` | dia | 60 dias |
| `trends`, `trends_uint` | mês | 12 meses |

O comando `maintain-all` não inicializa tabelas não particionadas por padrão. Para permitir essa inicialização, use `--init-missing`, avaliando antes o impacto em tabelas grandes:

```bash
./zbx_partition.sh maintain-all \
  --retention-history 60 \
  --retention-trends 12 \
  --init-missing \
  --yes
```

## Procedimento inicial recomendado

Execute esta sequência manualmente antes de configurar a automação.

### 1. Validar a sintaxe

```bash
bash -n zbx_partition.sh
```

### 2. Validar a conexão

```bash
./zbx_partition.sh status --table history
```

### 3. Gerar o SQL sem executar

```bash
./zbx_partition.sh init \
  --table history \
  --period day \
  --future 3 \
  --dry-run
```

Confira a quantidade e as datas das partições geradas.

### 4. Inicializar o particionamento

```bash
./zbx_partition.sh init \
  --table history \
  --period day \
  --future 3 \
  --yes
```

### 5. Conferir o resultado

```bash
./zbx_partition.sh status --table history
```

### 6. Testar a manutenção

A manutenção completa pode criar e remover partições. Faça esse teste somente depois de confirmar que a retenção está correta:

```bash
./zbx_partition.sh maintain \
  --table history \
  --period day \
  --future 3 \
  --retention 60 \
  --yes
```

## Automação no Linux com cron

O `cron` é suficiente para executar a manutenção uma vez por dia.

### 1. Instalar o script em um caminho fixo

```bash
sudo install -o root -g root -m 750 zbx_partition.sh /usr/local/sbin/zbx_partition.sh
```

### 2. Criar um diretório de logs

```bash
sudo install -d -o root -g root -m 750 /var/log/zabbix
```

### 3. Criar um arquivo de ambiente protegido

Crie `/etc/zabbix/zbx_partition.env` com:

```bash
ZBX_DB_HOST=192.168.68.241
ZBX_DB_PORT=3306
ZBX_DB_USER=lyjor
ZBX_DB_PASS=debian
ZBX_DB_NAME=zabbix
```

Proteja o arquivo:

```bash
sudo chown root:root /etc/zabbix/zbx_partition.env
sudo chmod 600 /etc/zabbix/zbx_partition.env
```

O usuário que executa o `cron` precisa conseguir ler esse arquivo. Se o cron executar como `root`, as permissões acima são adequadas.

### 4. Criar a tarefa diária

Crie `/etc/cron.d/zbx-partition` com:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

15 2 * * * root . /etc/zabbix/zbx_partition.env && /usr/local/sbin/zbx_partition.sh maintain-all --retention-history 60 --retention-trends 12 --future 3 --yes >> /var/log/zabbix/zbx-partition.log 2>&1
```

Essa configuração executa a manutenção todos os dias às 02:15, adicionando partições futuras e removendo partições fora da retenção.

### 5. Validar a tarefa

Confira o arquivo:

```bash
sudo cat /etc/cron.d/zbx-partition
```

Execute manualmente a mesma ação para testar:

```bash
sudo bash -c '. /etc/zabbix/zbx_partition.env && /usr/local/sbin/zbx_partition.sh maintain-all --retention-history 60 --retention-trends 12 --future 3 --yes'
```

Depois consulte o log:

```bash
sudo tail -n 100 /var/log/zabbix/zbx-partition.log
```

## Automação no Linux com systemd timer

Em distribuições que usam systemd, o timer oferece logs no journal e uma configuração mais explícita.

### 1. Criar o serviço

Crie `/etc/systemd/system/zbx-partition.service`:

```ini
[Unit]
Description=Manutencao das particoes do banco do Zabbix
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/zabbix/zbx_partition.env
ExecStart=/usr/local/sbin/zbx_partition.sh maintain-all --retention-history 60 --retention-trends 12 --future 3 --yes
```

### 2. Criar o timer

Crie `/etc/systemd/system/zbx-partition.timer`:

```ini
[Unit]
Description=Executa a manutencao das particoes do Zabbix diariamente

[Timer]
OnCalendar=*-*-* 02:15:00
Persistent=true

[Install]
WantedBy=timers.target
```

`Persistent=true` faz com que o serviço seja executado quando o servidor voltar a ligar caso o horário tenha sido perdido durante uma parada.

### 3. Ativar e testar

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now zbx-partition.timer
sudo systemctl start zbx-partition.service
sudo systemctl status zbx-partition.timer
sudo journalctl -u zbx-partition.service -n 100 --no-pager
```

Não use simultaneamente o `cron` e o `systemd timer` para a mesma manutenção, pois duas execuções concorrentes podem tentar alterar as partições ao mesmo tempo.

## Monitoramento e operação segura

Verifique periodicamente:

```bash
./zbx_partition.sh status-all
```

Também acompanhe os logs da automação. Uma falha de conexão, falta de privilégio ou erro no `ALTER TABLE` deve gerar uma saída diferente de zero e aparecer no log.

Recomendações:

- mantenha backup antes da primeira conversão e antes de reduzir a retenção;
- use `--dry-run` para revisar o SQL inicial;
- não use `--force` em produção sem um plano de rollback;
- garanta que o job seja executado antes que a última partição disponível fique insuficiente;
- não execute `cron` e `systemd timer` ao mesmo tempo;
- restrinja o acesso ao script, ao arquivo de ambiente e aos logs;
- monitore o crescimento das tabelas e o tempo de execução do `ALTER TABLE`.

## Fluxo completo resumido

```text
1. Instalar mysql-client e dependências
2. Configurar host, usuário, senha e banco
3. Validar bash -n
4. Testar status da tabela
5. Executar init com dry-run
6. Executar init uma única vez
7. Conferir com status
8. Configurar cron ou systemd timer
9. Executar maintain-all diariamente
10. Acompanhar logs e validar status-all
```
