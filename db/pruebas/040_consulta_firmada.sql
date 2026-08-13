-- =====================================================================
-- Invariante: una consulta firmada es historia clínica y no se edita
-- (§8.2.4, trigger `consulta_no_editar_firmada`, `050:247-278`).
--
-- Mientras es borrador se escribe libremente; al firmarla, el registro
-- queda cerrado. Lo único que la ley clínica admite después es la
-- anulación con motivo y las adendas, no el retoque del texto original.
--
-- La cerradura de verdad es el trigger: se prueba con UPDATE directo,
-- que es lo que haría cualquier atajo futuro por fuera de las funciones.
-- =====================================================================
BEGIN;
SELECT plan(10);

CREATE TEMP TABLE c AS
WITH vet AS (SELECT prueba.usuario(ARRAY['veterinario'], 'Veterinaria de prueba') AS id),
     pac AS (SELECT prueba.paciente() AS id),
     ab  AS (SELECT abrir_consulta((SELECT id FROM vet), (SELECT id FROM pac)) AS r)
SELECT (SELECT id FROM vet) AS vet_id,
       (SELECT id FROM pac) AS paciente_id,
       (SELECT (r->'consulta'->>'consulta_id')::uuid FROM ab) AS consulta_id;

SELECT is((SELECT estado FROM consulta WHERE id = (SELECT consulta_id FROM c)), 'borrador',
          'la consulta nace en borrador');

-- --- En borrador sí se escribe ---------------------------------------
SELECT ok((guardar_consulta_completa((SELECT vet_id FROM c), (SELECT consulta_id FROM c),
            '{"motivo_consulta":"Vómito","diagnostico_presuntivo":"Gastroenteritis",
              "plan_tratamiento":"Dieta blanda"}'::jsonb)->>'ok')::boolean,
          'en borrador se puede escribir');

-- --- La firma cierra --------------------------------------------------
SELECT ok((firmar_consulta((SELECT vet_id FROM c), (SELECT consulta_id FROM c))->>'ok')::boolean,
          'la consulta se firma');
SELECT is((SELECT estado FROM consulta WHERE id = (SELECT consulta_id FROM c)), 'firmada',
          'queda en estado firmada');
SELECT isnt((SELECT firmada_at FROM consulta WHERE id = (SELECT consulta_id FROM c)), NULL,
            'queda la marca de tiempo de la firma');

-- --- Ya firmada: nadie la edita --------------------------------------
SELECT throws_ok(
  format('UPDATE consulta SET motivo_consulta = ''otra cosa'' WHERE id = %L', consulta_id),
  'P0001', NULL, 'el trigger impide editar una consulta firmada') FROM c;
SELECT throws_ok(
  format('UPDATE consulta SET diagnostico_definitivo = ''otro'' WHERE id = %L', consulta_id),
  'P0001', NULL, 'tampoco se le cambia el diagnóstico') FROM c;

SELECT is((guardar_consulta((SELECT vet_id FROM c), (SELECT consulta_id FROM c),
            'motivo_consulta', 'otra cosa')->>'ok')::boolean, false,
          'la función de guardado también la rechaza');
SELECT is((SELECT motivo_consulta FROM consulta WHERE id = (SELECT consulta_id FROM c)), 'Vómito',
          'el texto original sigue intacto');

-- --- La anulación con motivo sí está permitida ------------------------
SELECT ok((anular_consulta((SELECT vet_id FROM c), (SELECT consulta_id FROM c),
            'Se firmó en el paciente equivocado')->>'ok')::boolean,
          'la corrección legítima es anular con motivo, y sí procede');

SELECT * FROM finish();
ROLLBACK;
