```
   _._
 o|- -|o This file is licensed under CC BY-NC-SA 4.0 international license.
  ( l )  To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
    =    Author: jean-marc "jihem" quere 2016
```

## firebird/fbclient
> Lab'Oratoire / Projet magenta - Laboratoire de Psycholinguistique Cognitive et Sociale \
> https://lipunila.sonaliwan.fr - metalab(at)sonaliwan.fr

**fbclient** est un binding Nim pour Firebird (disponible pour Linux, macOS et Windows*), écrit directement au-dessus de l'API C native (fbclient). Il offre une interface idiomatique et typée, sans dépendance à ODBC. Ses points forts :
- **Simple à utiliser** : connect, puis exec, query, getRow, getValue ou l'itérateur rows, avec des paramètres positionnels ? convertis automatiquement (toFb).
- **Transactions complètes** : une transaction par défaut avec autocommit, des transactions explicites avec options (isolation, attente, réservations de tables), des savepoints et le bloc withTransaction.
- Requêtes préparées : curseurs, `executeMany`, plan d'exécution, nombre de lignes affectées, etc.

*) En cas de rejet des bibliothèques fournies, récupérez les directement à partir d'une installation locale de FireBird.

Exemple
```
import firebird/fbclient

let db = connect("localhost:/data/test.fdb", "SYSDBA", "masterkey")
db.withTransaction(tx):
  discard tx.exec("INSERT INTO client (nom) VALUES (?)", "Dupont")
for r in db.rows("SELECT id, nom FROM client WHERE id > ?", 10):
  echo r.get("NOM", string)
```

Ce dépôt comporte les sources du client (dans src/firebird), les bibliothèques et un exemple (demo.nim). Vous devez disposer d'un serveur Firebird ([à télécharger](https://www.firebirdsql.org/en/server-packages/)) et **adapter les paramètres de connexion** (dans les variables d'environnement ou directement dans l'exemple : demo.nim). Les bibliothèquse clientes (libfbclient.so, libfbclient.dylib et libfbclient.dll) sont exploitées à partir de leur dossier respectif (linOS, macOS et winOS). Comme le logiciel Firebird, elles sont libres, gratuits et redistribuables, y compris dans des applications commerciales et propriétaires (voir FIREBIRD.md).

Usage (après `nimble build`):
```
./demo
```

**Firebird** => https://www.firebirdsql.org

Firebird est un système de gestion de **bases de données relationnelles (SGBDR) open source**, issu du code d'InterBase 6.0 publié par Borland en 2000. Il est développé par la communauté, sous licence IPL/IDPL, qui **autorise un usage commercial gratuit**. Il se distingue surtout par sa légèreté : une base tient dans un seul fichier (souvent .fdb), l'installation est minimale et l'administration quasi nulle. Il peut fonctionner en serveur classique (architectures SuperServer, Classic ou SuperClassic) ou en mode embarqué, intégré directement dans une application sans serveur séparé.

Sur le plan technique, il repose sur une architecture multi-générationnelle (MVCC), où les lecteurs ne bloquent pas les écrivains. Les transactions sont **ACID**, avec plusieurs niveaux d'isolation. Le **SQL est riche et conforme aux standards** : procédures stockées et triggers en PSQL, fonctions de fenêtrage, CTE récursives, séquences, BLOB et événements (POST_EVENT). C'est la base de données idéale pour les applications de gestion, les logiciels métiers, les solutions embarquées. Elle est principalement utilisée en Europe dans l'écosystème Delphi.

Pour un réel confort d'utilisation, je vous recommande d'utiliser [DBeaver Community](https://dbeaver.io) qui permet de travailler de façon très conforable avec les bases de données usuelles (dont duckDB et Firebird). Utilisateur de base de données depuis les années 90 (Microsoft SQL Server, HyperFile/SQL, MySQL/MariaDB, PostgreSQL, Interface/Firebird, ...), une seule n'a jamais failli... Je pense que vous êtes en mesure de deviner laquelle.

### Encore une chose !
Un p'tit geste qui peut - grandement - nous aider... \[La caféïne c'est important pour une équipe de neuro-atypiques : TSA, TDAH, TAG, HPI et/ou THPI (membres de **mensa.fr** et de **triplenine.org**).\]

[![Buy Me a Coffee](buymeacoffe-fre.png)](https://buymeacoffee.com/sonaliwan.fr)
