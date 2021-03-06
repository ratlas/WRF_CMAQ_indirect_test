!--------------------------------------------------------------------!
!  The Community Multiscale Air Quality (CMAQ) system software is in     !
!  continuous development by various groups and is based on information  !
!  from these groups: Federal Government employees, contractors working  !
!  within a United States Government contract, and non-Federal sources   !
!  including research institutions.  These groups give the Government    !
!  permission to use, prepare derivative works of, and distribute copies !
!  of their work in the CMAQ system to the public and to permit others   !
!  to do so.  The United States Environmental Protection Agency          !
!  therefore grants similar permission to use the CMAQ system software,  !
!  but users are requested to provide copies of derivative works or      !
!  products designed to operate in the CMAQ system to the United States  !
!  Government without restrictions as to use by others.  Software        !
!  that is used with the CMAQ system but distributed under the GNU       !
!  General Public License or the GNU Lesser General Public License is    !
!  subject to their copyright restrictions.                              !
!------------------------------------------------------------------------!


C RCS file, release, date & time of last delta, author, state, [and locker]
C $Header: /project/yoj/arc/CCTM/src/vdiff/acm2/vdiffacm2.F,v 1.13 2012/01/19 14:37:47 yoj Exp $

C:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
      SUBROUTINE VDIFFACMX ( DTSEC, SEDDY, DDEP, ICMP, DDEPJ, DDEPJ_FST, CNGRD )

C-----------------------------------------------------------------------
C Asymmetric Convective Model v2 (ACM2/ACM1) -- Pleim(2006/2014)
C Function:
C   calculates vertical diffusion

C Subroutines and Functions Called:
C   INIT3, SEC2TIME, TIME2SEC, WRITE3, NEXTIME,
C   M3EXIT, EDDYX, TRI, MATRIX, PA_UPDATE_EMIS, PA_UPDATE_DDEP

C Revision History:
C   Analogous to VDIFFACM2
C 11 Apr 13 J.Young: fix double adjustment of conc for DDBF in heterogeneous HONO
C           if-then-else clauses; eliminate some white space
C 13 May 13 J.Young: access met data from VDIFF_MET module
C                    change CRANKP to THBAR, CRANKQ to THETA
C 25 May 13 J.Young: re-do the acm/eddy algorithm for computational efficiency
C 30 Apr 14 J.Young: switch THBAR and THETA
C  2 May 14 J.Pleim, J.Young: replace the banded tridiagonal matrix solver for the
C           convective PBL, with the ACM1 matrix solver followed by the tridiagonal
C           matrix solver
C   30 May 14 J.Young: split vdiff calculation out of vdiff proc.
C-----------------------------------------------------------------------

      USE CGRID_SPCS          ! CGRID mechanism species
      USE GRID_CONF
      USE EMIS_DEFN          
      USE DEPV_DEFN
      USE VDIFF_MET
      USE VDIFF_MAP
      USE UTILIO_DEFN
      USE BIDI_MOD
      USE LSM_MOD, ONLY: N_LUFRAC
      USE VDIFF_DIAG, NLPCR => NLPCR_MEAN

      IMPLICIT NONE

      INCLUDE SUBST_PACTL_ID  ! PA control parameters
      INCLUDE SUBST_CONST     ! constants
      INCLUDE SUBST_FILES_ID  ! file name parameters

      CHARACTER( 120 ) :: XMSG = ' '

C Arguments:
      REAL, INTENT( IN )    :: DTSEC                ! model time step in seconds
C--- SEDDY is strictly an input, but it gets modified here
      REAL, INTENT( INOUT ) :: SEDDY    ( :,:,: )   ! flipped EDDYV
      REAL, INTENT( INOUT ) :: DDEP     ( :,:,: )   ! ddep accumulator
      REAL, INTENT( INOUT ) :: ICMP     ( :,:,: )   ! component flux accumlator 
      REAL, INTENT( INOUT ) :: DDEPJ    ( :,:,:,: ) ! ddep for mosaic
      REAL, INTENT( INOUT ) :: DDEPJ_FST( :,:,:,: ) ! ddep for stomtal/cuticular pathway
      REAL, INTENT( INOUT ) :: CNGRD    ( :,:,:,: ) ! cgrid replacement

C Parameters:

C explicit, THETA = 0, implicit, THETA = 1     ! Crank-Nicholson: THETA = 0.5
      REAL, PARAMETER :: THETA = 0.5,
     &                   THBAR = 1.0 - THETA

C ACM parameters

      REAL, PARAMETER :: KARMAN = 0.4
      REAL, PARAMETER :: EPS = 1.0E-06

C External Functions: None

C Local Variables:

      CHARACTER( 16 ), SAVE :: PNAME = 'VDIFFACMX'

      LOGICAL, SAVE :: FIRSTIME = .TRUE.

      REAL, ALLOCATABLE, SAVE :: DD_FAC     ( : )   ! combined subexpression
      REAL, ALLOCATABLE, SAVE :: DD_FACJ    ( :,: ) ! combined subexpression for mosaic
      REAL, ALLOCATABLE, SAVE :: DD_FACJ_FST( :,: ) ! combined subexpression for mosaic
      REAL, ALLOCATABLE, SAVE :: DDBF       ( : )   ! secondary DDEP
      REAL, ALLOCATABLE, SAVE :: DDBFJ      ( :,: ) ! secondary DDEP for mosaic
      REAL, ALLOCATABLE, SAVE :: DDBFJ_FST  ( :,: ) ! secondary DDEP for mosaic
      REAl, ALLOCATABLE, SAVE :: CMPF       ( : )   ! intermediate CMP
      REAL, ALLOCATABLE, SAVE :: CONC       ( :,: ) ! secondary CGRID expression
      REAL, ALLOCATABLE, SAVE :: EMIS       ( :,: ) ! emissions subexpression
      REAL        DTDENS1                       ! DT * layer 1 air density

C ACM Local Variables
      REAL     :: EDDY  ( NLAYS )               ! local converted eddyv
      REAL        MEDDY                         ! ACM2 intermediate var
      REAL        MBAR                          ! ACM2 mixing rate (S-1)
      REAL     :: MBARKS( NLAYS )               ! by layer
      REAL     :: MDWN  ( NLAYS )               ! ACM down mix rate
      REAL     :: MFAC  ( NLAYS )               ! intermediate loop factor
      REAL     :: AA    ( NLAYS )               ! matrix column one
      REAL     :: BB1   ( NLAYS )               ! diagonal for MATRIX1
      REAL     :: BB2   ( NLAYS )               ! diagonal for TRI
      REAL     :: CC    ( NLAYS )               ! subdiagonal
      REAL     :: EE1   ( NLAYS )               ! superdiagonal for MATRIX1
      REAL     :: EE2   ( NLAYS )               ! superdiagonal for TRI
      REAL, ALLOCATABLE, SAVE :: DD ( :,: )     ! R.H.S
      REAL, ALLOCATABLE, SAVE :: UU ( :,: )     ! returned solution
      REAL        DFACP, DFACQ
      REAL     :: DFSP( NLAYS ), DFSQ( NLAYS )  ! intermediate loop factors
      REAL        DELC, DELP, RP, RQ
      REAL     :: LFAC1( NLAYS )                ! intermediate factor for CONVT
      REAL     :: LFAC2( NLAYS )                ! intermediate factor for CONVT
      REAL     :: LFAC3( NLAYS )                ! intermediate factor for eddy
      REAL     :: LFAC4( NLAYS )                ! intermediate factor for eddy
      REAL, ALLOCATABLE, SAVE :: DEPVCR     ( : )   ! dep vel in one cell
      REAL, ALLOCATABLE, SAVE :: DEPVJCR    ( :,: ) ! dep vel in one cell for each landuse
                                                    ! category
      REAL, ALLOCATABLE, SAVE :: DEPVJCR_FST( :,: ) ! dep vel (stomatal uptake only) in
                                                    ! one cell for each landuse category
      REAL, ALLOCATABLE, SAVE :: EFAC1 ( : )
      REAL, ALLOCATABLE, SAVE :: EFAC2 ( : )
      REAL, ALLOCATABLE, SAVE :: POL   ( : )    ! prodn/lossrate = PLDV/DEPV
      REAL        PLDV_HONO                     ! PLDV for HONO
      REAL        DEPV_NO2                      ! dep vel of NO2
      REAL        DEPV_HNO3                     ! dep vel of HNO3
      REAL        FNL                           ! ACM2 Variable
      INTEGER     NLP, NL, LCBL
      INTEGER, SAVE :: NO2_HIT, HONO_HIT, HNO3_HIT, NO2_MAP, HNO3_MAP
      INTEGER, SAVE :: NH3_HIT
      REAL        DTLIM, DTS, DTACM, RZ

      INTEGER, SAVE :: LOGDEV
      INTEGER     ASTAT
      INTEGER     C, R, L, S, V, I, J           ! loop induction variables
      INTEGER     MDATE, MTIME                  ! internal simulation date&time

      INTERFACE
         SUBROUTINE MATRIX1 ( KL, A, B, E, D, X )
            IMPLICIT NONE
            INTEGER,        INTENT( IN )  :: KL
            REAL,           INTENT( IN )  :: A( : ), B( : ), E( : )
            REAL,           INTENT( IN )  :: D( :,: )
            REAL,           INTENT( OUT ) :: X( :,: )
         END SUBROUTINE MATRIX1
         SUBROUTINE TRI ( L, D, U, B, X )
            IMPLICIT NONE
            REAL,           INTENT( IN )  :: L( : ), D( : ), U( : )
            REAL,           INTENT( IN )  :: B( :,: )
            REAL,           INTENT( OUT ) :: X( :,: )
         END SUBROUTINE TRI
      END INTERFACE

C-----------------------------------------------------------------------

      IF ( FIRSTIME ) THEN

         FIRSTIME = .FALSE.
         LOGDEV = INIT3()

         MDATE = 0; MTIME = 0

C set auxiliary depv arrays

         ALLOCATE ( DD_FAC( N_SPC_DEPV  ),
     &              DDBF  ( N_SPC_DEPV ),
     &              DEPVCR( N_SPC_DEPV ),
     &              EFAC1 ( N_SPC_DEPV ),
     &              EFAC2 ( N_SPC_DEPV ),
     &              POL   ( N_SPC_DEPV ), STAT = ASTAT )
         IF ( ASTAT .NE. 0 ) THEN
            XMSG = 'Failure allocating DD_FAC, DDBF, DEPVCR, EFAC1, EFAC2, or POL'
            CALL M3EXIT( PNAME, MDATE, MTIME, XMSG, XSTAT1 )
         END IF

         IF ( MOSAIC ) THEN
            ALLOCATE ( DD_FACJ( N_LUFRAC,N_SPC_DEPV ),
     &                 DDBFJ  ( N_LUFRAC,N_SPC_DEPV ),
     &                 DEPVJCR( N_LUFRAC,N_SPC_DEPV ) )
            IF ( ASTAT .NE. 0 ) THEN
               XMSG = 'Failure allocating DD_FACJ, DDBFJ or DEPVJCR'
               CALL M3EXIT( PNAME, MDATE, MTIME, XMSG, XSTAT1 )
            END IF
            IF ( FST ) THEN
               ALLOCATE ( DD_FACJ_FST( N_LUFRAC,N_SPC_DEPV ),
     &                    DDBFJ_FST  ( N_LUFRAC,N_SPC_DEPV ),
     &                    DEPVJCR_FST( N_LUFRAC,N_SPC_DEPV ) )
               IF ( ASTAT .NE. 0 ) THEN
                  XMSG = 'Failure allocating DD_FACJ_FST, DDBFJ_FST or DEPVJCR_FST'
                  CALL M3EXIT( PNAME, MDATE, MTIME, XMSG, XSTAT1 )
               END IF
            END IF   ! if Fst
         END IF   ! if Mosaic

         ALLOCATE ( CMPF( LCMP ), STAT = ASTAT )
         IF ( ASTAT .NE. 0 ) THEN
            XMSG = 'Failure allocating CMPF'
            CALL M3EXIT( PNAME, MDATE, MTIME, XMSG, XSTAT1 )
         END IF

         ALLOCATE ( CONC( N_SPC_DIFF,NLAYS ),
     &              EMIS( N_SPC_DIFF,NLAYS ), STAT = ASTAT )
         IF ( ASTAT .NE. 0 ) THEN
            XMSG = 'Failure allocating CONC or EMIS'
            CALL M3EXIT( PNAME, MDATE, MTIME, XMSG, XSTAT1 )
         END IF
         CONC = 0.0; EMIS = 0.0   ! array assignment

         ALLOCATE ( DD( N_SPC_DIFF,NLAYS ),
     &              UU( N_SPC_DIFF,NLAYS ), STAT = ASTAT )
         IF ( ASTAT .NE. 0 ) THEN
            XMSG = 'Failure allocating DD or UU'
            CALL M3EXIT( PNAME, MDATE, MTIME, XMSG, XSTAT1 )
         END IF
         DD = 0.0; UU = 0.0   ! array assignment

         HONO_HIT = 0; HNO3_HIT = 0; NO2_HIT  = 0; NH3_HIT = 0
                       HNO3_MAP = 0; NO2_MAP  = 0
         DO V = 1, N_SPC_DEPV
            IF ( TRIM( DV2DF_SPC( V ) ) .EQ. 'NO2' ) THEN
               NO2_HIT = V
               NO2_MAP = DV2DF( V )
            ELSE IF ( TRIM( DV2DF_SPC( V ) ) .EQ. 'HONO' ) THEN
               HONO_HIT = V
            ELSE IF ( TRIM( DV2DF_SPC( V ) ) .EQ. 'HNO3' ) THEN
               HNO3_HIT = V
               HNO3_MAP = DV2DF( V )
            ELSE IF ( TRIM( DV2DF_SPC( V ) ) .EQ. 'NH3' ) THEN
               NH3_HIT = V
            END IF
         END DO

 
      END IF   !  if Firstime

C ------------------------------------------- Row, Col LOOPS -----------

      DO 345 R = 1, MY_NROWS
      DO 344 C = 1, MY_NCOLS

C for ACM time step
         DTLIM = DTSEC

C dt = .75 dzf*dzh / Kz
         DO L = 1, NLAYS - 1
            DTLIM = MIN( DTLIM, 0.75 / ( SEDDY( L,C,R ) * RDX3F( L ) ) )
         END DO
         MBARKS = 0.0   ! array assignment
         MDWN = 0.0     ! array assignment

C conjoin ACM & EDDY ---------------------------------------------------

         MBAR = 0.0
         FNL = 0.0

         IF ( CONVCT( C,R ) ) THEN   ! Do ACM for this column
            LCBL = LPBL( C,R )
            MEDDY = SEDDY( 1,C,R ) / ( XPBL( C,R ) - X3FACE_GD( 1 ) )
            FNL = 1.0 / ( 1.0 + ( ( KARMAN / ( -HOL( C,R ) ) ) ** 0.3333 )
     &                / ( 0.72 * KARMAN ) )
            MBAR = MEDDY * FNL
            IF ( MBAR .LT. EPS ) THEN
               WRITE( LOGDEV,* ) ' SEDDY, MBAR, FNL, HOL = ',
     &                             SEDDY( 1,C,R ), MBAR, FNL, HOL( C,R )
               XMSG = '*** ACM fails ***'
               CALL M3EXIT( PNAME, MDATE, MTIME, XMSG, XSTAT2 )
            END IF

            IF ( ( FNL .LE. 0.0 ) .OR.            ! never gonna happen for CONVCT
     &           ( LCBL .GE. NLAYS-1 ) .OR.       ! .GT. never gonna happen
     &           ( HOL( C,R ) .GT. -0.00001 ) )   ! never gonna happen
     &         WRITE( LOGDEV,1015 ) LCBL, MBAR, FNL, SEDDY( 1,C,R ), HOL( C,R )
1015           FORMAT( ' LCBL, MBAR, FNL, SEDDY1, HOL:', I3, 1X, 4(1PE13.5) )

            DO L = 1, LCBL - 1
               SEDDY( L,C,R ) = ( 1.0 - FNL ) * SEDDY( L,C,R  )
               MBARKS( L ) = MBAR
               MDWN( L ) = MBAR * ( XPBL( C,R ) - X3FACE_GD( L-1 ) ) * RDX3F( L )
            END DO
            MBARKS( LCBL ) = MBAR * ( XPBL( C,R ) - X3FACE_GD( LCBL-1 ) ) * RDX3F( LCBL )
            MDWN( LCBL ) = MBARKS( LCBL )

C Modify Timestep for ACM
            RZ     = ( X3FACE_GD( LCBL ) - X3FACE_GD( 1 ) ) * RDX3F( 1 )
            DTACM  = 1.0 / ( MBAR * RZ )
            DTLIM  = MIN( 0.75 * DTACM, DTLIM )
         ELSE
            LCBL = 1
         END IF

C-----------------------------------------------------------------------

         NLP = INT( DTSEC / DTLIM + 0.99 )
         IF ( VDIFFDIAG ) NLPCR( C,R ) = REAL( NLP )
         DTS = DTSEC / REAL( NLP )
         DTDENS1 = DTS * DENS1( C,R )
         DFACP = THETA * DTS
         DFACQ = THBAR * DTS

#ifdef Verbose_Vdiff
        IF ( R .EQ. MY_NROWS / 2 .AND. C .EQ. MY_NCOLS / 2 )
     &      WRITE( LOGDEV,1021 ) CONVCT( C,R ), DTS, EDDYV( C,R,1 ), MBAR, FNL
1021  FORMAT( ' CONVCT, DTS, EDDYV, MBAR, FNL: ', L3, 1X, 4(1PE13.5) )
#endif

         DO L = 1, NLAYS
            DO V = 1, N_SPC_DIFF
               CONC( V,L ) = CNGRD( DIFF_MAP( V ),L,C,R )
            END DO
         END DO

         EMIS = 0.0      ! array assignment
         DO L = 1, EMLAYS
            DO V = 1, N_SPC_DIFF
               EMIS( V,L ) = DTS * VDEMIS( DF2EM( V ),L,C,R )
            END DO
         END DO

         DO L = 1, NLAYS
            DFSP( L ) = DFACP * RDX3F( L )
            DFSQ( L ) = DFACQ * RDX3F( L )
            EDDY( L ) = SEDDY( L,C,R )
         END DO

         RP = DFACP * RDEPVHT( C,R )
         RQ = DFACQ * RDEPVHT( C,R )
         DO V = 1, N_SPC_DEPV
            DDBF( V )   = DDEP( V,C,R )
            DEPVCR( V ) = DEPV( V,C,R )
            DD_FAC( V ) = DTDENS1 * DD_CONV( V ) * DEPVCR( V )
            EFAC1 ( V ) = EXP( -DEPVCR( V ) * RP )
            EFAC2 ( V ) = EXP( -DEPVCR( V ) * RQ )
            POL   ( V ) = PLDV( V,C,R ) / DEPVCR( V )
            IF ( ABFLUX .AND. V .EQ. NH3_HIT ) THEN
               DO I = 1, LCMP          
                  CMPF( I ) = ICMP( I,C,R )
               END DO
            END IF            
         END DO
         PLDV_HONO = PLDV( HONO_HIT,C,R )

C These don`t change in the NLP sub-time step loop:---------------------
         DO L = 1, NLAYS
            AA ( L ) = 0.0
            BB1( L ) = 0.0
            EE1( L ) = 0.0
            CC ( L ) = 0.0
            EE2( L ) = 0.0
            BB2( L ) = 0.0
         END DO
         IF ( CONVCT( C,R ) ) THEN
            L = 1
            DELP = XPBL( C,R ) - X3FACE_GD( L )
            BB1( L ) = 1.0 + DELP * DFSP( L ) * MBARKS( L )
            LFAC1( L ) = DFSQ( L ) * DELP * MBARKS( L )
            LFAC2( L ) = DFSQ( L ) * MDWN( L+1 ) * DX3F( L+1 )
            DO L = 2, LCBL
               AA ( L ) = -DFACP * MBARKS( L )
               BB1( L ) = 1.0 + DFACP * MDWN( L )
               EE1( L ) = -DFSP( L-1 ) * DX3F( L ) * MDWN( L )
               MFAC( L ) = DX3F( L+1 ) * RDX3F( L ) * MDWN( L+1 )
            END DO
         END IF

         DO L = 1, NLAYS
            EE2( L ) = - DFSP( L ) * EDDY( L )
            LFAC3( L ) = DFSQ( L ) * EDDY( L )
         END DO

         BB2( 1 ) = 1.0 - EE2( 1 )
         DO L = 2, NLAYS
            CC ( L ) = - DFSP( L ) * EDDY( L-1 )
            BB2( L ) = 1.0 - CC( L ) - EE2( L )
            LFAC4( L ) = DFSQ( L ) * EDDY( L-1 )
         END DO
C ----------------------------------------------------------------------

         IF ( MOSAIC ) THEN
            DO V = 1, N_SPC_DEPV
               DO J = 1, N_LUFRAC
                  DDBFJ( J,V )   = DDEPJ( J,V,C,R )
                  DEPVJCR( J,V ) = DEPVJ( J,V,C,R )
                  DD_FACJ( J,V ) = DTDENS1 * DD_CONV( V ) * DEPVJCR( J,V )
               END DO
            END DO
            IF ( FST ) THEN
               DO V = 1, N_SPC_DEPV
                  DO J = 1, N_LUFRAC
                     DDBFJ_FST( J,V )   = DDEPJ_FST( J,V,C,R )
                     DEPVJCR_FST( J,V ) = DEPVJ_FST( J,V,C,R )
                     DD_FACJ_FST( J,V ) = DTDENS1 * DD_CONV( V ) * DEPVJCR_FST( J,V )
                  END DO
               END DO
            END IF
         END IF

C-----------------------------------------------------------------------

         DO 301 NL = 1, NLP      ! loop over sub time

            DO V = 1, N_SPC_DEPV

C --------- HET HONO RX -----------------

C Use special treatment for HNO3
C HNO3 produced via the heterogeneous reaction sticks on surfaces and
C is accounted as depositional loss; calculate increased deposition loss
               IF ( V .EQ. HNO3_HIT ) THEN
                  S = HNO3_MAP
                  CONC( S,1 ) = POL( V ) + ( CONC( S,1 ) - POL( V ) ) * EFAC1( V )
                  DEPV_HNO3 = DEPVCR( V ) + PLDV_HONO / CONC( NO2_MAP,1 )
                  DD_FAC( V ) = DTDENS1 * DD_CONV( V ) * DEPV_HNO3
                  DDBF( V ) = DDBF( V ) + THETA * DD_FAC( V ) * CONC( S,1 )

C Use special treatment for NO2
C Loss of NO2 via the heterogeneous reaction is accounted for as an additional
C depositional loss. Add the loss of NO2 via the heterogeneous reaction
C to the regular deposition velocity (increased dep. vel.).  This will
C reduce the NO2 conc. in the atmosphere without affecting the depositional loss.
               ELSE IF ( V .EQ. NO2_HIT ) THEN
                  S = NO2_MAP
                  DEPV_NO2 = DEPVCR( V ) + 2.0 * PLDV_HONO / CONC( S,1 )
                  EFAC1 ( V ) = EXP( -DEPV_NO2 * RP )
                  EFAC2 ( V ) = EXP( -DEPV_NO2 * RQ )
                  POL   ( V ) = PLDV( V,C,R ) / DEPV_NO2
                  CONC( S,1 ) = POL( V ) + ( CONC( S,1 ) - POL( V ) ) * EFAC1( V )
                  DDBF( V ) = DDBF( V ) + THETA * DD_FAC( V ) * CONC( S,1 )
  
C --------- END of HET HONO RX ----------

               ELSE
                  S = DV2DF( V )
                  CONC( S,1 ) = POL( V ) + ( CONC( S,1 ) - POL( V ) ) * EFAC1( V )
                  DDBF( V ) = DDBF( V ) + THETA * DD_FAC( V ) * CONC( S,1 )

                  IF ( ABFLUX .AND. V .EQ. NH3_HIT ) THEN
                     DO I = 1, LCMP        
                        CMPF( I ) = CMPF( I ) + THETA * CMP( I,C,R ) * DD_CONV( V ) * DTDENS1
                     END DO
                  END IF
               END IF

            END DO
    
            IF ( MOSAIC ) THEN
               DO V = 1, N_SPC_DEPV
C --------------- HET HONO RX -----------------
                  IF ( V .EQ. HNO3_HIT ) THEN
                     S = HNO3_MAP
                     DO J = 1, N_LUFRAC
                        DEPV_HNO3 = DEPVJCR( J,V ) + PLDV_HONO / CONC( NO2_MAP,1 )
                        DD_FACJ( J,V ) = DTDENS1 * DD_CONV( V ) * DEPV_HNO3
                        DDBFJ( J,V ) = DDBFJ( J,V ) + THETA * DD_FACJ( J,V ) * CONC( S,1 )
                     END DO
C --------------- END of HET HONO RX ----------

                  ELSE
                     S = DV2DF( V )
                     DO J = 1, N_LUFRAC
                        DDBFJ( J,V ) = DDBFJ( J,V )
     &                               + THETA * DD_FACJ( J,V ) * CONC( S,1 )
                     END DO
                  END IF
               END DO
               IF ( FST ) THEN
                  DO V = 1, N_SPC_DEPV
                     IF ( V .EQ. HNO3_HIT ) THEN
                        S = HNO3_MAP
                        DO J = 1, N_LUFRAC
                           DEPV_HNO3 = DEPVJCR_FST( J,V ) + PLDV_HONO / CONC( NO2_MAP,1 )
                           DD_FACJ_FST( J,V ) = DTDENS1 * DD_CONV( V ) * DEPV_HNO3
                           DDBFJ_FST( J,V ) = DDBFJ_FST( J,V )
     &                                      + THETA * DD_FACJ_FST( J,V ) * CONC( S,1 )
                        END DO
                     ELSE
                        S = DV2DF( V )
                        DO J = 1, N_LUFRAC
                           DDBFJ_FST( J,V ) = DDBFJ_FST( J,V )
     &                                      + THETA * DD_FACJ_FST( J,V ) * CONC( S,1 )
                        END DO
                     END IF
                  END DO
               END IF   ! FST

            END IF   ! MOSAIC

            DO L = 1, NLAYS
               DO V = 1, N_SPC_DIFF
                  DD( V,L ) = 0.0
                  UU( V,L ) = 0.0
               END DO
            END DO

C Compute tendency of CBL concentrations - semi-implicit solution
C Set MATRIX1 elements A (col 1), B (diag.), E (superdiag.) and D (RHS)

            IF ( CONVCT( C,R ) ) THEN

               L = 1
               DO V = 1, N_SPC_DIFF
                  DD( V,L ) = CONC( V,L )
     &                      - LFAC1( L ) * CONC( V,L )
     &                      + LFAC2( L ) * CONC( V,L+1 ) 
               END DO

               DO L = 2, LCBL
                  DO V = 1, N_SPC_DIFF
                     DELC = MBARKS( L ) * CONC( V,1 )
     &                    -   MDWN( L ) * CONC( V,L )
     &                    +   MFAC( L ) * CONC( V,L+1 )
                     DD( V,L ) = CONC( V,L ) + DFACQ * DELC
                  END DO
               END DO

               CALL MATRIX1 ( LCBL, AA, BB1, EE1, DD, UU )

C update conc
               DO L = 1, LCBL
                  DO V = 1, N_SPC_DIFF
                     CONC( V,L ) = UU( V,L )
                  END DO
               END DO

C reinitialize for TRI solver
               DO L = 1, NLAYS
                  DO V = 1, N_SPC_DIFF
                     DD( V,L ) = 0.0
                     UU( V,L ) = 0.0
                  END DO
               END DO

            END IF

            L = 1
            DO V = 1, N_SPC_DIFF
               DD( V,L ) = CONC( V,L )
     &                   + LFAC3( L ) * ( CONC( V,L+1 ) - CONC( V,L ) )
     &                   + EMIS( V,L )
            END DO

            DO L = 2, NLAYS-1
               DO V = 1, N_SPC_DIFF
                  DD( V,L ) = CONC( V,L )
     &                      + LFAC3( L ) * ( CONC( V,L+1 ) - CONC( V,L ) )
     &                      - LFAC4( L ) * ( CONC( V,L ) - CONC( V,L-1 ) )
     &                      + EMIS( V,L )
               END DO
            END DO

            L = NLAYS
            DO V = 1, N_SPC_DIFF
               DD( V,L ) = CONC( V,L )
     &                   - LFAC4( L ) * ( CONC( V,L ) - CONC( V,L-1 ) )
            END DO

            CALL TRI ( CC, BB2, EE2, DD, UU )

C Load into CGRID
            DO L = 1, NLAYS
               DO V = 1, N_SPC_DIFF
                  CONC( V,L ) = UU( V,L )
               END DO
            END DO
            
            DO V = 1, N_SPC_DEPV

C --------- HET HONO RX -----------------

               IF ( V .EQ. HNO3_HIT ) THEN
                  S = HNO3_MAP
                  CONC( S,1 ) = POL( V ) + ( CONC( S,1 ) - POL( V ) ) * EFAC2( V )
                  DDBF( V ) = DDBF( V ) + THBAR * DD_FAC( V ) * CONC( S,1 )

               ELSE IF ( V .EQ. NO2_HIT ) THEN
                  S = NO2_MAP
                  CONC( S,1 ) = POL( V ) + ( CONC( S,1 ) - POL( V ) ) * EFAC2( V )
                  DDBF( V ) = DDBF( V ) + THBAR * DD_FAC( V ) * CONC( S,1 )

C --------- END of HET HONO RX ----------

               ELSE
                  S = DV2DF( V )
                  CONC( S,1 ) = POL( V ) + ( CONC( S,1 ) - POL( V ) ) * EFAC2( V )
                  DDBF( V ) = DDBF( V ) + THBAR * DD_FAC( V ) * CONC( S,1 )

                  IF ( ABFLUX .AND. V .EQ. NH3_HIT ) THEN
                     DO I = 1, LCMP
                        CMPF( I ) = CMPF( I ) + THBAR * CMP( I,C,R ) * DD_CONV( V ) * DTDENS1   
                     END DO
                  END IF

               END IF

            END DO
    
            IF ( MOSAIC ) THEN
               DO V = 1, N_SPC_DEPV
                  IF ( V .EQ. HNO3_HIT ) THEN
                     S = HNO3_MAP
                     DO J = 1, N_LUFRAC
                        DEPV_HNO3 = DEPVJCR( J,V ) + PLDV_HONO / CONC( NO2_MAP,1 )
                        DD_FACJ( J,V ) = DTDENS1 * DD_CONV( V ) * DEPV_HNO3
                        DDBFJ( J,V ) = DDBFJ( J,V ) + THBAR * DD_FACJ( J,V ) * CONC( S,1 )
                     END DO
                  ELSE
                     S = DV2DF( V )
                     DO J = 1, N_LUFRAC
                        DDBFJ( J,V ) = DDBFJ( J,V ) + THBAR * DD_FACJ( J,V ) * CONC( S,1 )
                     END DO
                  END IF
               END DO
               IF ( FST ) THEN
                  DO V = 1, N_SPC_DEPV
                     IF ( V .EQ. HNO3_HIT ) THEN
                        S = HNO3_MAP
                        DO J = 1, N_LUFRAC
                           DEPV_HNO3 = DEPVJCR_FST( J,V ) + PLDV_HONO / CONC( NO2_MAP,1 )
                           DD_FACJ_FST( J,V ) = DTDENS1 * DD_CONV( V ) * DEPV_HNO3
                           DDBFJ_FST( J,V ) = DDBFJ_FST( J,V )
     &                                      + THBAR * DD_FACJ_FST( J,V ) * CONC( S,1 )
                        END DO
                     ELSE
                        S = DV2DF( V )
                        DO J = 1, N_LUFRAC
                           DDBFJ_FST( J,V ) = DDBFJ_FST( J,V )
     &                                      + THBAR * DD_FACJ_FST( J,V ) * CONC( S,1 )
                        END DO
                     END IF
                  END DO
               END IF   ! FST
            END IF   ! MOSAIC

301      CONTINUE                 ! end sub time loop

         DO L = 1, NLAYS
            DO V = 1, N_SPC_DIFF
               CNGRD( DIFF_MAP( V ),L,C,R ) = CONC( V,L )
            END DO
         END DO

         DO V = 1, N_SPC_DEPV
            DDEP( V,C,R ) = DDBF( V )
         END DO
 
         IF ( ABFLUX ) THEN
            DO I = 1, LCMP
               ICMP( I,C,R ) = CMPF( I )
            END DO
         END IF
 
         IF ( MOSAIC ) THEN
            DO V = 1, N_SPC_DEPV
               DO J = 1, N_LUFRAC
                  DDEPJ( J,V,C,R ) = DDBFJ( J,V )
               END DO
            END DO
            IF ( FST ) THEN
               DO V = 1, N_SPC_DEPV
                  DO J = 1, N_LUFRAC
                     DDEPJ_FST( J,V,C,R ) = DDBFJ_FST( J,V )
                  END DO
               END DO
            END IF
         END IF

344   CONTINUE         !  end loop on col C
345   CONTINUE         !  end loop on row R

      RETURN
      END
