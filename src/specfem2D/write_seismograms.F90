!========================================================================
!
!                   S P E C F E M 2 D  Version 7 . 0
!                   --------------------------------
!
!     Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                        Princeton University, USA
!                and CNRS / University of Marseille, France
!                 (there are currently many more authors!)
! (c) Princeton University and CNRS / University of Marseille, April 2014
!
! This software is a computer program whose purpose is to solve
! the two-dimensional viscoelastic anisotropic or poroelastic wave equation
! using a spectral-element method (SEM).
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 2 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
! The full text of the license is available in file "LICENSE".
!
!========================================================================

! write seismograms to text files

  subroutine write_seismograms()

  use constants, only: ZERO
  use specfem_par
  use specfem_par_gpu, only: Mesh_pointer

  implicit none

  ! local parameters
  integer :: i, j, iglob, irecloc, ispec
  double precision :: valux,valuz,valcurl

  ! vector field in an element
  real(kind=CUSTOM_REAL), dimension(NDIM,NGLLX,NGLLZ) :: vector_field_element
  ! pressure in an element
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLZ) :: pressure_element
  ! curl in an element
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLZ) :: curl_element

  ! checks subsampling recurrence
  if (mod(it-1,subsamp_seismos) == 0) then

    ! update position in seismograms
    seismo_current = seismo_current + 1

    ! check for edge effects
    if (seismo_current < 1 .or. seismo_current > NSTEP/subsamp_seismos) &
      stop 'Error: seismo_current out of bounds in recording of seismograms'

    ! updates local receiver records
    if (nrecloc > 0) then

      ! computes seismogram entry for all local receivers
      if (.not. GPU_MODE) then
        ! on CPU
        do irecloc = 1,nrecloc

          ispec = ispec_selected_rec_loc(irecloc)

          !debug
          !print *,'ispec',ispec,ispec_is_acoustic(ispec),ispec_is_elastic(ispec), &
          !                ispec_is_gravitoacoustic(ispec),ispec_is_poroelastic(ispec)

          ! initializes local element arrays
          vector_field_element(:,:,:) = 0._CUSTOM_REAL
          pressure_element(:,:) = 0._CUSTOM_REAL
          curl_element(:,:) = 0._CUSTOM_REAL

          ! compute seismo/pressure/curl in this element
          select case (seismotype)
          case (1)
            ! displacement
            call compute_vector_one_element(potential_acoustic,potential_gravitoacoustic, &
                                            potential_gravito,displ_elastic,displs_poroelastic, &
                                            ispec,vector_field_element)
          case (2)
            ! velocity
            call compute_vector_one_element(potential_dot_acoustic,potential_dot_gravitoacoustic, &
                                            potential_dot_gravito,veloc_elastic,velocs_poroelastic, &
                                            ispec,vector_field_element)
          case (3)
            ! acceleration
            call compute_vector_one_element(potential_dot_dot_acoustic,potential_dot_dot_gravitoacoustic, &
                                            potential_dot_dot_gravito,accel_elastic,accels_poroelastic, &
                                            ispec,vector_field_element)
          case (4)
            ! pressure
            call compute_pressure_one_element(ispec,pressure_element)

          case (5)
            ! displacement
            call compute_vector_one_element(potential_acoustic,potential_gravitoacoustic, &
                                            potential_gravito,displ_elastic,displs_poroelastic, &
                                            ispec,vector_field_element)
            ! curl of displacement
            call compute_curl_one_element(ispec,curl_element)

          case (6)
            ! fluid potential
            ! uses pressure_element to store local element values
            if (ispec_is_acoustic(ispec)) then
              do j = 1,NGLLZ
                do i = 1,NGLLX
                  iglob = ibool(i,j,ispec)
                  pressure_element(i,j) = potential_acoustic(iglob)
                enddo
              enddo
            else if (ispec_is_gravitoacoustic(ispec)) then
              do j = 1,NGLLZ
                do i = 1,NGLLX
                  iglob = ibool(i,j,ispec)
                  pressure_element(i,j) = potential_gravitoacoustic(iglob)
                enddo
              enddo
            endif

          case default
            stop 'Invalid seismotype for writing seismograms'
          end select

          ! perform the general interpolation using Lagrange polynomials
          call compute_interpolated_dva(irecloc,ispec,vector_field_element,pressure_element,curl_element, &
                                        valux,valuz,valcurl)

          ! rotate seismogram components if needed, except if recording pressure, which is a scalar
          if (seismotype == 4 .or. seismotype == 6) then
            ! pressure/potential type has only single component
            sisux(seismo_current,irecloc) = valux
            sisuz(seismo_current,irecloc) = ZERO
          else
            if (P_SV) then
              sisux(seismo_current,irecloc) =   cosrot_irec(irecloc)*valux + sinrot_irec(irecloc)*valuz
              sisuz(seismo_current,irecloc) = - sinrot_irec(irecloc)*valux + cosrot_irec(irecloc)*valuz
            else
              sisux(seismo_current,irecloc) = valux
              sisuz(seismo_current,irecloc) = ZERO
            endif
            ! additional curl case
            if (seismotype == 5) siscurl(seismo_current,irecloc) = valcurl
          endif
        enddo ! irecloc

      else
        ! on GPU
        if (SIMULATION_TYPE == 1) then
          ! Simulating seismograms
          if (USE_TRICK_FOR_BETTER_PRESSURE) then
            call compute_seismograms_cuda(Mesh_pointer,seismotype,sisux,sisuz,seismo_current, &
                                                       NSTEP/subsamp_seismos, &
                                                       ELASTIC_SIMULATION,ACOUSTIC_SIMULATION,1)
          else
            call compute_seismograms_cuda(Mesh_pointer,seismotype,sisux,sisuz,seismo_current, &
                                                       NSTEP/subsamp_seismos, &
                                                       ELASTIC_SIMULATION,ACOUSTIC_SIMULATION,0)
          endif
          ! note: curl not implemented yet
        endif
      endif ! GPU_MODE

    endif ! nrecloc

  endif ! subsamp_seismos

  ! save temporary or final seismograms
  if (it == NSTEP)  call write_seismograms_to_file(sisux,sisuz,siscurl)

  end subroutine write_seismograms

!================================================================

  subroutine write_seismograms_to_file(sisux,sisuz,siscurl)

#ifdef USE_MPI
  use mpi
#endif

  use constants, only: NDIM,MAX_LENGTH_NETWORK_NAME,MAX_LENGTH_STATION_NAME,OUTPUT_FILES

  use specfem_par, only: station_name,network_name,NSTEP,islice_selected_rec,nrec,myrank,deltat,seismotype,t0, &
                         subsamp_seismos,nrecloc, &
                         P_SV,SU_FORMAT,save_ASCII_seismograms, &
                         save_binary_seismograms_single,save_binary_seismograms_double,x_source,z_source

  implicit none

  double precision,dimension(NSTEP/subsamp_seismos,nrecloc),intent(in) :: sisux,sisuz,siscurl

  ! local parameters
  logical :: save_binary_seismograms
  integer :: irec,length_station_name,length_network_name,iorientation,isample,number_of_components

  character(len=4) :: channel
  character(len=1) :: component
  character(len=4) :: suffix
  character(len=150) :: sisname

  ! to write seismograms in single precision SEP and double precision binary format
  double precision, dimension(:,:,:), allocatable :: buffer_binary
  double precision :: time_t
  real, dimension(:), allocatable :: single_precision_seismo

  integer :: irecloc
  integer :: ier
  integer :: length_seismo_bin

! write seismograms

  ! save displacement, velocity, acceleration or pressure
  if (seismotype == 1) then
    component = 'd'
  else if (seismotype == 2) then
    component = 'v'
  else if (seismotype == 3) then
    component = 'a'
  else if (seismotype == 4 .or. seismotype == 6) then
    component = 'p'
  else if (seismotype == 5) then
    component = 'c'
  else
    call exit_MPI(myrank,'wrong component to save for seismograms')
  endif

  ! only one seismogram if pressures or SH (membrane) waves
  if (seismotype == 4 .or. seismotype == 6 .or. .not. P_SV) then
    number_of_components = 1
  else if (seismotype == 5) then
    ! adds curl
    number_of_components = NDIM + 1
  else
    number_of_components = NDIM
  endif

  allocate(buffer_binary(NSTEP/subsamp_seismos,nrec,number_of_components),stat=ier)
  allocate(single_precision_seismo(NSTEP/subsamp_seismos),stat=ier)
  if (ier /= 0) stop 'Error allocating array buffer_binary'
  buffer_binary(:,:,:) = 0.d0

  ! see if we need to save any seismogram in binary format
  save_binary_seismograms = save_binary_seismograms_single .or. save_binary_seismograms_double

  ! binary file output
  if (save_binary_seismograms .and. myrank == 0) then
    ! filename extension
    if (.not. SU_FORMAT) then
      suffix = '.bin'
      length_seismo_bin = NSTEP/subsamp_seismos
    else
      suffix = '.su'
      length_seismo_bin = NSTEP/subsamp_seismos + 60
    endif

    ! deletes old files
    open(unit=12,file=trim(OUTPUT_FILES)//'Ux_file_single'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Ux_file_double'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Uy_file_single'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Uy_file_double'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Uz_file_single'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Uz_file_double'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Up_file_single'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Up_file_double'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Uc_file_single'//suffix,status='unknown')
    close(12,status='delete')

    open(unit=12,file=trim(OUTPUT_FILES)//'Uc_file_double'//suffix,status='unknown')
    close(12,status='delete')

    ! write the new files
    if (save_binary_seismograms_single) then
      if (seismotype == 4 .or. seismotype == 6) then
        open(unit=12,file=trim(OUTPUT_FILES)//'Up_file_single'//suffix,status='unknown',access='direct',recl=4*length_seismo_bin)
      else if (.not. P_SV) then
        open(unit=12,file=trim(OUTPUT_FILES)//'Uy_file_single'//suffix,status='unknown',access='direct',recl=4*length_seismo_bin)
      else
        open(unit=12,file=trim(OUTPUT_FILES)//'Ux_file_single'//suffix,status='unknown',access='direct',recl=4*length_seismo_bin)
      endif
    endif

    if (save_binary_seismograms_double) then
      if (seismotype == 4 .or. seismotype == 6) then
        ! continue without output
      else if (.not. P_SV) then
        open(unit=13,file=trim(OUTPUT_FILES)//'Uz_file_double'//suffix,status='unknown',access='direct',recl=8*length_seismo_bin)
      else
        open(unit=13,file=trim(OUTPUT_FILES)//'Ux_file_double'//suffix,status='unknown',access='direct',recl=8*length_seismo_bin)
      endif
    endif

    ! no Z component seismogram if pressure
    if (seismotype /= 4 .and. seismotype /= 6 .and. P_SV) then
      if (save_binary_seismograms_single) &
        open(unit=14,file=trim(OUTPUT_FILES)//'Uz_file_single'//suffix,status='unknown',access='direct',recl=4*length_seismo_bin)
      if (save_binary_seismograms_double) &
        open(unit=15,file=trim(OUTPUT_FILES)//'Uz_file_double'//suffix,status='unknown',access='direct',recl=8*length_seismo_bin)
    endif

    ! curl output
    if (seismotype == 5) then
      if (save_binary_seismograms_single) &
        open(unit=16,file=trim(OUTPUT_FILES)//'Uc_file_single'//suffix,status='unknown',access='direct',recl=4*length_seismo_bin)
      if (save_binary_seismograms_double) &
        open(unit=17,file=trim(OUTPUT_FILES)//'Uc_file_double'//suffix,status='unknown',access='direct',recl=8*length_seismo_bin)
    endif
  endif ! save_binary_seismograms

  ! sets seismogram values
  irecloc = 0
  do irec = 1,nrec
    if (myrank == 0) then

      if (myrank == islice_selected_rec(irec)) then
        irecloc = irecloc + 1

        ! fills buffer
        buffer_binary(:,irec,1) = sisux(:,irecloc)
        if (number_of_components == 2) then
          buffer_binary(:,irec,2) = sisuz(:,irecloc)
        else if (number_of_components == 3) then
          ! adds curl trace
          buffer_binary(:,irec,2) = sisuz(:,irecloc)
          buffer_binary(:,irec,3) = siscurl(:,irecloc)
        endif

#ifdef USE_MPI
      else
        ! collects seismogram components on master
        call recv_dp(buffer_binary(1,irec,1), NSTEP/subsamp_seismos, islice_selected_rec(irec), irec)

        if (number_of_components == 2) then
          call recv_dp(buffer_binary(1,irec,2), NSTEP/subsamp_seismos, islice_selected_rec(irec), irec)
        endif

        if (number_of_components == 3) then
          call recv_dp(buffer_binary(1,irec,2), NSTEP/subsamp_seismos, islice_selected_rec(irec), irec)
          call recv_dp(buffer_binary(1,irec,3), NSTEP/subsamp_seismos, islice_selected_rec(irec), irec)
        endif
#endif
      endif
    endif ! myrank == 0
  enddo

  irecloc = 0
  do irec = 1,nrec
    if (myrank == 0) then

      if (.not. SU_FORMAT) then

        if (save_ASCII_seismograms) then

          ! write trace
          do iorientation = 1,number_of_components

            if (iorientation == 1) then
              channel = 'BXX'
            else if (iorientation == 2) then
              channel = 'BXZ'
            else if (iorientation == 3) then
              channel = 'cur'
            else
              call exit_MPI(myrank,'incorrect channel value')
            endif

            ! in case of pressure, use different abbreviation
            if (seismotype == 4 .or. seismotype == 6) channel = 'PRE'

            ! in case of SH (membrane) waves, use different abbreviation
            if (.not. P_SV) channel = 'BXY'

            ! create the name of the seismogram file for each slice
            ! file name includes the name of the station, the network and the component
            length_station_name = len_trim(station_name(irec))
            length_network_name = len_trim(network_name(irec))

            ! check that length conforms to standard
            if (length_station_name < 1 .or. length_station_name > MAX_LENGTH_STATION_NAME) then
              call exit_MPI(myrank,'wrong length of station name')
            endif
            if (length_network_name < 1 .or. length_network_name > MAX_LENGTH_NETWORK_NAME) then
              call exit_MPI(myrank,'wrong length of network name')
            endif

            write(sisname,"(a,a,'.',a,'.',a3,'.sem',a1)") &
            trim(OUTPUT_FILES),network_name(irec)(1:length_network_name),station_name(irec)(1:length_station_name),channel,component

            ! deletes old seismogram file when starting to write output
            open(unit=11,file=sisname(1:len_trim(sisname)),status='unknown')
            close(11,status='delete')

            open(unit=11,file=sisname(1:len_trim(sisname)),status='unknown',position='append')

            ! make sure we never write more than the maximum number of time steps
            ! subtract offset of the source to make sure travel time is correct
            do isample = 1,NSTEP/subsamp_seismos

              ! forward time
              time_t = dble(isample - 1) * deltat - t0

              write(11,*) time_t,' ',buffer_binary(isample,irec,iorientation)
            enddo

            close(11)
          enddo ! iorientation

        endif ! save_ASCII_seismograms

        ! write binary seismogram
        if (save_binary_seismograms) then

          if (save_binary_seismograms_single) then
            do isample = 1, NSTEP/subsamp_seismos
              single_precision_seismo(isample) = sngl(buffer_binary(isample,irec,1))
            enddo
            write(12,rec=irec) single_precision_seismo
          endif
          if (save_binary_seismograms_double) &
            write(13,rec=irec) buffer_binary(:,irec,1)

          if (seismotype /= 4 .and. seismotype /= 6 .and. P_SV) then
            if (save_binary_seismograms_single) then
              do isample = 1, NSTEP/subsamp_seismos
                single_precision_seismo(isample) = sngl(buffer_binary(isample,irec,2))
              enddo
              write(14,rec=irec) single_precision_seismo
            endif
            if (save_binary_seismograms_double) &
              write(15,rec=irec) buffer_binary(:,irec,2)
          endif

          if (seismotype == 5) then
            if (save_binary_seismograms_single) then
              do isample = 1, NSTEP/subsamp_seismos
                single_precision_seismo(isample) = sngl(buffer_binary(isample,irec,3))
              enddo
              write(16,rec=irec) single_precision_seismo
            endif
            if (save_binary_seismograms_double) &
              write(17,rec=irec) buffer_binary(:,irec,3)
          endif

        endif

      else
        ! if SU_FORMAT
        call write_output_SU(x_source(1),z_source(1),irec,buffer_binary,number_of_components)
      endif

#ifdef USE_MPI
    else
      ! slave processes (myrank > 0)
      ! sends seismogram values to master
      if (myrank == islice_selected_rec(irec)) then
        irecloc = irecloc + 1
        call send_dp(sisux(1,irecloc), NSTEP/subsamp_seismos, 0, irec)

        if (number_of_components >= 2) then
          call send_dp(sisuz(1,irecloc), NSTEP/subsamp_seismos, 0, irec)
        endif

        if (number_of_components == 3) then
          call send_dp(siscurl(1,irecloc), NSTEP/subsamp_seismos, 0, irec)
        endif

      endif
#endif

    endif ! myrank

  enddo

  ! closes files
  if (save_binary_seismograms_single) close(12)
  if (save_binary_seismograms_double) close(13)
  if (seismotype /= 4 .and. seismotype /= 6 .and. P_SV) then
    if (save_binary_seismograms_single) close(14)
    if (save_binary_seismograms_double) close(15)
  endif
  if (seismotype == 5) then
    if (save_binary_seismograms_single) close(16)
    if (save_binary_seismograms_double) close(17)
  endif

  ! frees temporary buffer
  deallocate(buffer_binary)

  end subroutine write_seismograms_to_file

