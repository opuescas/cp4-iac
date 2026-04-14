#!/usr/bin/env bash

echo -e "\n--- Estado de la Suscripción ---"
oc get subscription openshift-cert-manager-operator -n cert-manager-operator -o custom-columns=NAME:.metadata.name,STATE:.status.state,CURRENT_CSV:.status.currentCSV

echo -e "\n--- Estado del Install Plan ---"
oc get installplan -n cert-manager-operator

echo -e "\n--- Pods Inicializando ---"
oc get pods -n cert-manager-operator

echo -e "\n--- Canales Disponibles ---"
oc get packagemanifest openshift-cert-manager-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}{"\n"}'
