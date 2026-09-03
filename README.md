# Reblex
Iha hullu säännöt edelleen 1 ei tiivistelyjä placebo fake koodia keskeneräidtä koodia! 2 vain oikeaa parasta kunnolla mietitty parasta aito koodia joka varmasti toimii eikp ole leikkikoodia

## MorphLabFE.lua

FE-skripti, joka muuttaa oman hahmosi neljaksi eri olennoksi. Ei luo uusia parteja - raajat asetetaan uusiin paikkoihin joka frame, joten kaikki pelaajat nakevat sen (100% FE). Toimii R6:lla (ensisijainen) ja R15:lla (varavirta raajaketjuilla).

### Moodit
- HELICOPTER: vartalo=runko makuulla, paa=ohjaamo, o.kasi=masto selasta ylos, o.jalka=paapotkuri, v.kasi=hantapuomi, v.jalka=hantapotkuri. HYPPY=nousu (paapotkuri kihahtaa), DESCEND=lasku (potkurit hiljenevat), eteenpain=nokka kallistuu + hantapotkuri kiihtyy. Special: CRASHOUT.
- BUNNY: kadet=korvat jousitettuina (reagoivat kiihtyvyyteen), jalat=potkujalat, oikea pomppufysiikka squash & stretch -efektilla. HYPPY=iso pomppu, DUCK=kyykky. Special: THUMP.
- DOG: neljajalkainen, vinottainen rava-askel. HYPPY=karkaus, SIT=istuminen. Special: BOW.
- MONSTER: raskas keinuva hahmo, pitkat kadet. HYPPY=iskema, CROUCH=kuperkeikko. Special: ROAR.

### GUI (englanniksi, ei emojeita)
- Lapinakyva, raahattava, pienennettava (- nappi), gradientit
- Moodivalinnat pill-painikkeina, ENABLE/DISABLE, SPECIAL-nappi
- DESCEND-nappi ilmestyy hypynapin viereen (PC:lla myos CTRL)
- RightShift = piilota/nayta GUI
