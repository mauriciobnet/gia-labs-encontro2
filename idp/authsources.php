<?php

$config = array(

    'admin' => array(
        'core:AdminPassword',
    ),

    'example-userpass' => array(
        'exampleauth:UserPass',
        // uid 'user1' e não '1': o identity provider usa principalAttribute=uid, e o user
        // profile do Keycloak exige username com no mínimo 3 caracteres. Com uid=1 o usuário
        // reprova na validação e o Keycloak abre a tela "Update Account Information" no
        // primeiro login, que parece erro do lab e não é.
        //
        // De propósito NÃO mandamos givenName nem sn: é assim que a maioria dos IdPs externos
        // se comporta, e o script do lab já torna firstName/lastName opcionais no realm.
        'user1:user1pass' => array(
            'uid' => array('user1'),
            'eduPersonAffiliation' => array('group1'),
            'email' => 'user1@parceiro.example.com',
        ),
        'user2:user2pass' => array(
            'uid' => array('user2'),
            'eduPersonAffiliation' => array('group2'),
            'email' => 'user2@parceiro.example.com',
        ),
    ),

);
